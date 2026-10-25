package dev.instantbarcode.instant_barcode_scanner

import android.content.Context
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcodeFormat
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformDetectionSpeed
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformRect
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformSnapshot
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformState

/**
 * The camera2 mechanism.
 *
 * States, as physical configurations of the camera stack:
 *
 *   live    device open, session [preview + analysis], repeating running
 *   parked  device open, session kept, repeating stopped
 *   open    device open, no session at all
 *   closed  no device, no session (texture survives for the next round)
 *
 * Commands are latest-target-wins. [driveTo] records the requested target and
 * one convergence pump walks the physical stack toward it, one async step at
 * a time. A newer command retargets the running pump instead of starting a
 * second one, so `close` issued while the device is still opening always ends
 * with the device actually closed, and every pending future completes only on
 * a platform-confirmed snapshot.
 *
 * All state lives on a single camera thread; public calls post to it.
 * Callbacks ([onStateChanged], [onBarcodes], `driveTo` results) are delivered
 * on the main thread.
 *
 * @param previewSurface provider for the Flutter texture surface. Called on
 *   the camera thread; must return the same surface for the mechanism's
 *   lifetime.
 * @param onPreviewSize called on the camera thread once the chosen preview
 *   size is known, so the texture buffer can be resized.
 * @param onStateChanged confirmed stable-state snapshots, main thread.
 * @param onBarcodes decoded barcode batches, main thread. Only emitted while
 *   `live`.
 */
internal class CameraMechanism(
    private val context: Context,
    private val previewSurface: () -> Surface?,
    private val onPreviewSize: (width: Int, height: Int) -> Unit,
    private val onStateChanged: (PlatformSnapshot) -> Unit,
    private val onBarcodes: (List<PlatformBarcode>) -> Unit,
    private val selection: () -> CameraSelection,
    formats: List<PlatformBarcodeFormat>,
    detectionSpeed: PlatformDetectionSpeed,
    detectionTimeoutMs: Int,
    initialScanWindow: PlatformRect?,
    invertImage: Boolean,
    initialTorch: Boolean,
    private val initialZoom: Double?,
    targetWidth: Int?,
    targetHeight: Int?,
) {
    companion object {
        private const val TAG = "InstantScanner"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val maxAnalysisWidth = targetWidth ?: 1280
    private val maxAnalysisHeight = targetHeight ?: 720

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var sensorRotation = 90
    private var selectedCameraId: String? = null

    /** Bumped on every switch; stale open callbacks must not claim the camera. */
    private var selectionGeneration = 0L

    private var hasFlash = false
    private var torchEnabled = initialTorch
    private var zoomMin = 1f
    private var zoomMax = 1f
    private var zoomRatio: Float? = null
    private var pendingZoomRatio: Float? = null
    private var resetZoomOnOpen = false
    private var activeArray: Rect? = null

    @Volatile private var streaming = false

    private val analysis = BarcodeAnalysisPipeline(
        context = context,
        formats = formats,
        detectionSpeed = detectionSpeed,
        detectionTimeoutMs = detectionTimeoutMs.toLong(),
        initialScanWindow = initialScanWindow,
        invertImage = invertImage,
        isLive = { streaming },
        onBarcodes = onBarcodes,
    )

    /** False once [dispose] has been called; no new work is accepted. */
    @Volatile private var accepting = true

    /** Set on the camera thread before teardown; the pump drains and exits. */
    private var shuttingDown = false
    private var disposed = false
    private var onDisposedCallback: (() -> Unit)? = null

    private enum class Step { NONE, OPENING, CONFIGURING }

    private data class Target(
        val device: Boolean,
        val session: Boolean,
        val streaming: Boolean,
    )

    private var activeStep = Step.NONE
    private var requested: Target? = null
    private var requestedSeq = 0L
    private var commandSeq = 0L

    private var lastEmitted: PlatformSnapshot? = null
    private val pendingResults = mutableListOf<(PlatformSnapshot) -> Unit>()

    fun driveTo(target: PlatformState, result: (PlatformSnapshot) -> Unit) {
        if (!accepting) {
            result(detachedSnapshot("scanner has been disposed"))
            return
        }
        cameraHandlerFor().post {
            val to = when (target) {
                PlatformState.CLOSED -> Target(device = false, session = false, streaming = false)
                PlatformState.OPEN -> Target(device = true, session = false, streaming = false)
                PlatformState.PARKED -> Target(device = true, session = true, streaming = false)
                PlatformState.LIVE -> Target(device = true, session = true, streaming = true)
                else -> null
            }
            if (to == null) {
                postResult(
                    result,
                    PlatformSnapshot(
                        currentState(), "invalid_target", "cannot drive to $target"
                    )
                )
                return@post
            }
            if (!accepting) {
                postResult(result, detachedSnapshot("scanner has been disposed"))
                return@post
            }
            requested = to
            requestedSeq = ++commandSeq
            pendingResults.add(result)
            pump()
        }
    }

    /**
     * Re-open the camera with the current [selection] provider, restoring the
     * state that was confirmed before the switch. Runs through the same pump
     * as drives, so callers only see confirmed snapshots.
     */
    fun switchCamera(result: (PlatformSnapshot) -> Unit) {
        if (!accepting) {
            result(detachedSnapshot("scanner has been disposed"))
            return
        }
        cameraHandlerFor().post {
            if (!accepting) {
                postResult(result, detachedSnapshot("scanner has been disposed"))
                return@post
            }
            val restoreTo = requested ?: targetForState(currentState())
            selectionGeneration++
            stopRepeating()
            closeSession()
            closeDevice()
            selectedCameraId = null
            torchEnabled = false
            zoomRatio = null
            // A new camera starts at its widest field of view, matching the
            // controller resetting its normalized zoom to 0.
            pendingZoomRatio = null
            resetZoomOnOpen = true
            requested = restoreTo
            requestedSeq = ++commandSeq
            pendingResults.add(result)
            pump()
        }
    }

    /** Applies immediately: the pipeline reads the window per decode. */
    fun setScanWindow(window: PlatformRect?) {
        analysis.setScanWindow(window)
    }

    /** Torch is a live-only control; enabling it while not streaming stores it. */
    fun setTorch(enabled: Boolean, result: (Boolean, String?) -> Unit) {
        cameraHandlerFor().post {
            if (!accepting) {
                postCommandResult(result, false, "scanner has been disposed")
                return@post
            }
            if (enabled && !hasFlash) {
                postCommandResult(result, false, "torch is not available")
                return@post
            }
            torchEnabled = enabled
            if (!streaming) {
                postCommandResult(result, true, null)
                return@post
            }
            val error = startRepeating()
            postCommandResult(result, error == null, error)
        }
    }

    /** Zoom applies immediately when live; otherwise it is stored for the next start. */
    fun setZoom(ratio: Double, result: (Double?, String?) -> Unit) {
        cameraHandlerFor().post {
            if (!accepting) {
                postCommandResult(result, null, "scanner has been disposed")
                return@post
            }
            val targetRatio = ratio.toFloat()
            pendingZoomRatio = targetRatio
            if (device == null) {
                postCommandResult(result, targetRatio.toDouble(), null)
                return@post
            }
            val applied = targetRatio.coerceIn(zoomMin, zoomMax)
            zoomRatio = applied
            pendingZoomRatio = applied
            if (streaming) {
                val error = startRepeating()
                if (error != null) {
                    postCommandResult(result, null, error)
                    return@post
                }
            }
            postCommandResult(result, applied.toDouble(), null)
        }
    }

    private fun targetForState(state: PlatformState): Target {
        return when (state) {
            PlatformState.LIVE -> Target(device = true, session = true, streaming = true)
            PlatformState.PARKED -> Target(device = true, session = true, streaming = false)
            PlatformState.OPEN -> Target(device = true, session = false, streaming = false)
            else -> Target(device = false, session = false, streaming = false)
        }
    }

    private fun <T> postCommandResult(
        result: (T, String?) -> Unit,
        value: T,
        error: String?,
    ) {
        mainHandler.post {
            try {
                result(value, error)
            } catch (t: Throwable) {
                Log.w(TAG, "command result callback failed", t)
            }
        }
    }

    /**
     * Truthfully close the camera and release every resource. Completes
     * [onDisposed] on the main thread after teardown, once any in-flight
     * convergence step has drained.
     */
    fun dispose(onDisposed: (() -> Unit)? = null) {
        if (disposed) {
            onDisposed?.invoke()
            return
        }
        accepting = false
        onDisposedCallback = onDisposed
        val h = handler
        if (h == null) {
            shutdownOnCameraThread()
            return
        }
        h.post {
            shuttingDown = true
            if (activeStep == Step.NONE) {
                shutdownOnCameraThread()
            }
            // Otherwise the in-flight step's callback re-enters pump(), which
            // notices shuttingDown and runs the teardown.
        }
    }

    private fun cameraHandlerFor(): Handler {
        var h = handler
        if (h == null) {
            val t = HandlerThread("ibs-camera2").apply { start() }
            thread = t
            h = Handler(t.looper)
            handler = h
        }
        return h
    }

    private fun currentState(): PlatformState {
        return when {
            device == null -> PlatformState.CLOSED
            session == null -> PlatformState.OPEN
            !streaming -> PlatformState.PARKED
            else -> PlatformState.LIVE
        }
    }

    private fun detachedSnapshot(message: String): PlatformSnapshot =
        PlatformSnapshot(PlatformState.FAILED, "disposed", message)

    /**
     * Single-flight convergence toward [requested]. Runs on the camera thread;
     * async steps re-enter through their callbacks. The pump never blocks on
     * an older target: it re-reads [requested] at every entry, so a retarget
     * during `open`/`configure` is picked up as soon as the step completes.
     */
    private fun pump() {
        if (shuttingDown) {
            if (activeStep == Step.NONE) {
                shutdownOnCameraThread()
            }
            return
        }
        // A step is already running. The retarget is recorded; the step's
        // callback re-enters here when it completes.
        if (activeStep != Step.NONE) {
            return
        }
        val target = requested ?: return

        if (!target.device) {
            stopRepeating()
            closeSession()
            closeDevice()
            finish(PlatformSnapshot(currentState(), null, null))
            return
        }

        if (device == null) {
            activeStep = Step.OPENING
            val seq = requestedSeq
            openDevice { ok, message ->
                activeStep = Step.NONE
                when {
                    shuttingDown || !accepting -> pump()
                    ok -> pump()
                    requested == null -> Unit
                    requestedSeq != seq -> pump()
                    else -> abort("open_failed", message ?: "camera device failed to open")
                }
            }
            return
        }

        if (!target.session) {
            stopRepeating()
            closeSession()
            finish(PlatformSnapshot(currentState(), null, null))
            return
        }

        if (session == null) {
            activeStep = Step.CONFIGURING
            val seq = requestedSeq
            configureSession { ok, message ->
                activeStep = Step.NONE
                when {
                    shuttingDown || !accepting -> pump()
                    ok -> pump()
                    requested == null -> Unit
                    requestedSeq != seq -> pump()
                    else -> abort("configure_failed", message ?: "capture session failed to configure")
                }
            }
            return
        }

        if (target.streaming && !streaming) {
            val error = startRepeating()
            if (error == null) {
                finish(PlatformSnapshot(currentState(), null, null))
            } else {
                abort("repeating_failed", error)
            }
            return
        }

        if (!target.streaming && streaming) {
            stopRepeating()
            finish(PlatformSnapshot(currentState(), null, null))
            return
        }

        finish(PlatformSnapshot(currentState(), null, null))
    }

    /**
     * Failed convergence is not a state to sit in: close everything, forget
     * the request and report the physical truth plus the error. Runs on the
     * camera thread.
     */
    private fun abort(code: String, message: String?) {
        stopRepeating()
        closeSession()
        closeDevice()
        requested = null
        finish(PlatformSnapshot(PlatformState.CLOSED, code, message))
    }

    /**
     * Publish a confirmed state: emit a state-changed event when it differs
     * from the last one, and complete every pending `driveTo` future with it.
     * Runs on the camera thread.
     */
    private fun finish(snapshot: PlatformSnapshot) {
        val callbacks = pendingResults.toList()
        pendingResults.clear()
        mainHandler.post {
            emitChanged(snapshot)
            callbacks.forEach { callback ->
                try {
                    callback(snapshot)
                } catch (t: Throwable) {
                    Log.w(TAG, "driveTo result callback failed", t)
                }
            }
        }
    }

    private fun postResult(callback: (PlatformSnapshot) -> Unit, snapshot: PlatformSnapshot) {
        mainHandler.post {
            try {
                callback(snapshot)
            } catch (t: Throwable) {
                Log.w(TAG, "driveTo result callback failed", t)
            }
        }
    }

    private fun emitChanged(snapshot: PlatformSnapshot) {
        val previous = lastEmitted
        if (previous != null &&
            previous.state == snapshot.state &&
            previous.errorCode == snapshot.errorCode
        ) {
            return
        }
        lastEmitted = snapshot
        onStateChanged(snapshot)
    }

    /** Teardown runs on the camera thread (or the caller's thread if none
     * was ever started). */
    private fun shutdownOnCameraThread() {
        if (disposed) {
            return
        }
        disposed = true
        stopRepeating()
        closeSession()
        closeDevice()
        analysis.shutdown()
        finish(PlatformSnapshot(PlatformState.CLOSED, null, null))
        thread?.quitSafely()
        thread = null
        handler = null
        mainHandler.post { onDisposedCallback?.invoke() }
    }

    private fun openDevice(done: (Boolean, String?) -> Unit) {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = try {
            resolveCameraId(manager, selection())
        } catch (t: Throwable) {
            Log.w(TAG, "no camera", t)
            done(false, "no camera is available")
            return
        }
        val generation = selectionGeneration
        selectedCameraId = camId
        try {
            val characteristics = manager.getCameraCharacteristics(camId)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            if (map != null) {
                val size = bestSize(
                    map.getOutputSizes(SurfaceTexture::class.java),
                    maxAnalysisWidth,
                    maxAnalysisHeight,
                )
                onPreviewSize(size.width, size.height)
            }
            sensorRotation = sensorOrientation(characteristics)
            hasFlash =
                characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            val zoom = zoomInfo(characteristics)
            zoomMin = zoom.min.toFloat()
            zoomMax = zoom.max.toFloat()
            activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            zoomRatio = when {
                resetZoomOnOpen -> zoomMin
                pendingZoomRatio != null -> pendingZoomRatio
                else -> initialZoom?.let {
                    val fraction = it.coerceIn(0.0, 1.0).toFloat()
                    zoomMin + fraction * (zoomMax - zoomMin)
                }
            }?.coerceIn(zoomMin, zoomMax)
            resetZoomOnOpen = false
            pendingZoomRatio = zoomRatio
        } catch (t: Throwable) {
            Log.w(TAG, "camera characteristics failed", t)
            done(false, "camera characteristics could not be read")
            return
        }
        try {
            manager.openCamera(
                camId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(dev: CameraDevice) {
                        if (generation != selectionGeneration) {
                            try {
                                dev.close()
                            } catch (_: Throwable) {
                            }
                            done(false, "camera selection changed while opening")
                            return
                        }
                        device = dev
                        done(true, null)
                    }

                    override fun onDisconnected(dev: CameraDevice) {
                        try {
                            dev.close()
                        } catch (_: Throwable) {
                        }
                        if (activeStep == Step.OPENING && device == null) {
                            done(false, "camera disconnected while opening")
                            return
                        }
                        if (device !== dev) {
                            return
                        }
                        device = null
                        session = null
                        streaming = false
                        unexpectedLoss("disconnected", "camera device was disconnected")
                    }

                    override fun onError(dev: CameraDevice, error: Int) {
                        try {
                            dev.close()
                        } catch (_: Throwable) {
                        }
                        if (activeStep == Step.OPENING && device == null) {
                            done(false, "camera error $error while opening")
                            return
                        }
                        if (device !== dev) {
                            return
                        }
                        device = null
                        session = null
                        streaming = false
                        unexpectedLoss("device_error", "camera device error $error")
                    }
                },
                cameraHandlerFor(),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "openCamera failed", t)
            done(false, "camera device could not be opened")
        }
    }

    /**
     * The camera died while we held it. There is no recovery to guess at:
     * close what is left and report the loss on the current snapshot. The
     * policy layer decides whether to re-drive. Runs on the camera thread.
     */
    private fun unexpectedLoss(code: String, message: String) {
        if (disposed || shuttingDown) {
            return
        }
        stopRepeating()
        closeSession()
        abort(code, message)
    }

    private fun closeDevice() {
        val dev = device ?: return
        try {
            dev.close()
        } catch (_: Throwable) {
        }
        device = null
    }

    private fun configureSession(done: (Boolean, String?) -> Unit) {
        val dev = device ?: run {
            done(false, "camera device is not open")
            return
        }
        val preview = previewSurface() ?: run {
            done(false, "preview surface is not available")
            return
        }
        val surfaces = mutableListOf(preview)
        val cameraId = selectedCameraId ?: run {
            done(false, "camera device is not open")
            return
        }
        val analysisTarget = try {
            analysis.target(
                sensorRotation,
                cameraId,
                maxAnalysisWidth,
                maxAnalysisHeight,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "analysis reader failed", t)
            done(false, "analysis target could not be created")
            return
        }
        surfaces.add(analysisTarget)
        try {
            @Suppress("DEPRECATION")
            dev.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        if (device == null || shuttingDown) {
                            try {
                                s.close()
                            } catch (_: Throwable) {
                            }
                            done(false, "capture session became stale")
                            return
                        }
                        session = s
                        done(true, null)
                    }

                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        Log.w(TAG, "capture session configure failed")
                        done(false, "capture session failed to configure")
                    }
                },
                cameraHandlerFor(),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "createCaptureSession failed", t)
            done(false, "capture session could not be created")
        }
    }

    private fun closeSession() {
        val s = session ?: return
        try {
            s.close()
        } catch (_: Throwable) {
        }
        session = null
        streaming = false
    }

    private fun startRepeating(): String? {
        val dev = device ?: return "camera device is not open"
        val s = session ?: return "capture session is not configured"
        val preview = previewSurface() ?: return "preview surface is not available"
        val cameraId = selectedCameraId ?: return "camera device is not open"
        try {
            val request = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            request.addTarget(preview)
            try {
                request.addTarget(
                    analysis.target(
                        sensorRotation,
                        cameraId,
                        maxAnalysisWidth,
                        maxAnalysisHeight,
                    ),
                )
            } catch (t: Throwable) {
                Log.w(TAG, "analysis target missing", t)
            }
            if (torchEnabled && hasFlash) {
                request.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            }
            applyZoom(request)
            s.setRepeatingRequest(request.build(), null, cameraHandlerFor())
            analysis.newGeneration()
            streaming = true
            return null
        } catch (t: Throwable) {
            Log.w(TAG, "setRepeatingRequest failed", t)
            return "repeating request failed: ${t.message}"
        }
    }

    private fun applyZoom(request: CaptureRequest.Builder) {
        val ratio = zoomRatio ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            request.set(CaptureRequest.CONTROL_ZOOM_RATIO, ratio)
            return
        }
        val active = activeArray ?: return
        if (ratio <= 1f) {
            request.set(CaptureRequest.SCALER_CROP_REGION, active)
            return
        }
        val width = (active.width() / ratio).toInt().coerceAtLeast(1)
        val height = (active.height() / ratio).toInt().coerceAtLeast(1)
        val left = active.centerX() - width / 2
        val top = active.centerY() - height / 2
        request.set(
            CaptureRequest.SCALER_CROP_REGION,
            Rect(left, top, left + width, top + height),
        )
    }

    private fun stopRepeating() {
        val s = session ?: return
        if (!streaming) {
            return
        }
        try {
            s.stopRepeating()
        } catch (_: Throwable) {
        }
        try {
            s.abortCaptures()
        } catch (_: Throwable) {
        }
        streaming = false
        // Torch is a live-only control: leaving live releases the flash too.
        torchEnabled = false
    }

}

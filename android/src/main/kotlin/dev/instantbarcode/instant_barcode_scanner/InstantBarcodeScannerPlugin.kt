package dev.instantbarcode.instant_barcode_scanner

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.instantbarcode.instant_barcode_scanner.pigeon.FlutterError
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCameraFacing
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCameraLensType
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCapabilities
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformDetectionSpeed
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformRect
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformScannerConfig
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformSnapshot
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformState
import dev.instantbarcode.instant_barcode_scanner.pigeon.ScannerFlutterApi
import dev.instantbarcode.instant_barcode_scanner.pigeon.ScannerHostApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Flutter entry point for the scanner.
 *
 * Owns the preview texture and wires the pigeon host API to
 * [CameraMechanism]. All camera work happens in the mechanism; this class
 * only translates calls and events.
 *
 * [dispose] is a reset, not a shutdown: the mechanism is torn down so the
 * camera is truthfully released, but the plugin stays attached, keeps the
 * preview texture (it is engine-scoped, not controller-scoped) and serves
 * the next controller with a fresh mechanism. The texture is released only
 * when the engine detaches.
 *
 * When the host activity is stopped the camera is driven to `closed`
 * deliberately — backgrounded apps lose camera access on Android 9+ anyway,
 * and we would rather close than be disconnected. The scanner does not
 * auto-reopen on return; the app calls `warmUp()` again.
 */
class InstantBarcodeScannerPlugin : FlutterPlugin, ActivityAware, ScannerHostApi {
    private companion object {
        const val PERMISSION_REQUEST_CODE = 0x1B5
    }

    private var registry: TextureRegistry? = null
    private var applicationContext: Context? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var mechanism: CameraMechanism? = null
    private var scanWindow: PlatformRect? = null
    private var flutterApi: ScannerFlutterApi? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

    @Volatile
    private var scannerConfig = PlatformScannerConfig(
        facing = PlatformCameraFacing.BACK,
        lensType = PlatformCameraLensType.ANY,
        formats = emptyList(),
        torchEnabled = false,
        detectionSpeed = PlatformDetectionSpeed.NORMAL,
        detectionTimeoutMs = 250L,
        invertImage = false,
    )

    @Volatile
    private var selection = CameraSelection(
        PlatformCameraFacing.BACK,
        PlatformCameraLensType.ANY,
    )

    private var permissionResume: ((Boolean) -> Unit)? = null
    private val permissionListener =
        PluginRegistry.RequestPermissionsResultListener { requestCode, _, grantResults ->
            if (requestCode != PERMISSION_REQUEST_CODE) {
                return@RequestPermissionsResultListener false
            }
            val granted =
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            val resume = permissionResume
            permissionResume = null
            resume?.invoke(granted)
            true
        }

    /** Last state the mechanism confirmed; drives the close/HAL wait. */
    @Volatile
    private var lastState: PlatformState = PlatformState.CLOSED
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        registry = binding.textureRegistry
        applicationContext = binding.applicationContext
        flutterApi = ScannerFlutterApi(binding.binaryMessenger)
        ScannerHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ScannerHostApi.setUp(binding.binaryMessenger, null)
        val current = mechanism
        mechanism = null
        flutterApi = null
        if (current != null) {
            current.dispose { releaseTexture() }
        } else {
            releaseTexture()
        }
        registry = null
        applicationContext = null
        permissionResume?.invoke(false)
        permissionResume = null
        scope.cancel()
    }

    override suspend fun configure(config: PlatformScannerConfig) {
        scannerConfig = config
        selection = CameraSelection(config.facing, config.lensType)
        // Configuration is per controller: a new controller starts without a
        // scan window inherited from the previous session.
        scanWindow = null
    }

    override suspend fun getTextureId(): Long = mutex.withLock {
        var current = entry
        if (current == null) {
            val reg = registry
                ?: throw FlutterError(
                    "detached",
                    "plugin is not attached to a Flutter engine",
                    null,
                )
            current = reg.createSurfaceTexture()
            entry = current
            surface = Surface(current.surfaceTexture())
        }
        current.id()
    }

    override suspend fun getCapabilities(): PlatformCapabilities {
        val context = applicationContext
            ?: throw FlutterError(
                "detached",
                "plugin is not attached to a Flutter engine",
                null,
            )
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = try {
            resolveCameraId(manager, selection)
        } catch (t: Throwable) {
            throw FlutterError(
                "camera_unavailable",
                "no camera could be resolved for the requested facing",
                t.message,
            )
        }
        val characteristics = manager.getCameraCharacteristics(cameraId)
        val zoom = zoomInfo(characteristics)
        val hasFlash =
            characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        return PlatformCapabilities(
            supportsPark = true,
            supportsTrueClose = true,
            supportsTorch = hasFlash,
            supportsZoom = zoom.max > zoom.min,
            minZoom = zoom.min,
            maxZoom = zoom.max,
        )
    }

    override suspend fun driveTo(target: PlatformState): PlatformSnapshot {
        if (target != PlatformState.CLOSED && !ensureCameraPermission()) {
            return PlatformSnapshot(
                PlatformState.FAILED,
                "permission_denied",
                "camera permission was not granted",
            )
        }
        // Register the availability watch *before* the close drive: the
        // callback reports the unavailable -> available transition, and a
        // watcher registered afterwards can miss it and stall for the full
        // timeout. When the device is already gone (closed/failed) there is
        // no transition to wait for.
        val needsAvailabilityWait =
            target == PlatformState.CLOSED &&
                lastState != PlatformState.CLOSED &&
                lastState != PlatformState.FAILED
        val watch = if (needsAvailabilityWait) {
            applicationContext?.let { context ->
                try {
                    val manager =
                        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    CameraAvailabilityWatch(
                        context,
                        resolveCameraId(manager, selection),
                    ).also { it.start() }
                } catch (_: Throwable) {
                    null
                }
            }
        } else {
            null
        }
        try {
            val snapshot = mutex.withLock {
                val current = ensureMechanism()
                    ?: return@withLock PlatformSnapshot(
                        PlatformState.FAILED,
                        "detached",
                        "plugin is not attached to a Flutter engine",
                    )
                suspendCancellableCoroutine { continuation ->
                    current.driveTo(target) { confirmed ->
                        if (continuation.isActive) {
                            continuation.resume(confirmed)
                        }
                    }
                }
            }
            // The close contract of §9: a closed snapshot means the device
            // object is gone, and completion additionally means the camera HAL
            // reports the camera available again — safe to hand over to NFC.
            if (snapshot.state == PlatformState.CLOSED) {
                watch?.await()
            }
            return snapshot
        } finally {
            watch?.close()
        }
    }

    override suspend fun switchCamera(
        facing: PlatformCameraFacing,
        lensType: PlatformCameraLensType,
    ): PlatformSnapshot {
        selection = CameraSelection(facing, lensType)
        val current = mechanism ?: return PlatformSnapshot(PlatformState.CLOSED, null, null)
        if (!ensureCameraPermission()) {
            return PlatformSnapshot(
                PlatformState.FAILED,
                "permission_denied",
                "camera permission was not granted",
            )
        }
        return mutex.withLock {
            suspendCancellableCoroutine { continuation ->
                current.switchCamera { snapshot ->
                    if (continuation.isActive) {
                        continuation.resume(snapshot)
                    }
                }
            }
        }
    }

    override suspend fun setTorch(enabled: Boolean) {
        val current = mechanism
            ?: throw FlutterError("not_running", "the scanner is not open", null)
        val outcome = mutex.withLock {
            suspendCancellableCoroutine<Pair<Boolean, String?>> { continuation ->
                current.setTorch(enabled) { ok, message ->
                    if (continuation.isActive) {
                        continuation.resume(ok to message)
                    }
                }
            }
        }
        if (!outcome.first) {
            throw FlutterError(
                "unsupported",
                outcome.second ?: "the torch command failed",
                null,
            )
        }
    }

    override suspend fun setZoom(ratio: Double) {
        val current = mechanism
            ?: throw FlutterError("not_running", "the scanner is not open", null)
        val outcome = mutex.withLock {
            suspendCancellableCoroutine<Pair<Double?, String?>> { continuation ->
                current.setZoom(ratio) { applied, message ->
                    if (continuation.isActive) {
                        continuation.resume(applied to message)
                    }
                }
            }
        }
        if (outcome.first == null) {
            throw FlutterError(
                "unsupported",
                outcome.second ?: "the zoom command failed",
                null,
            )
        }
    }

    override suspend fun updateScanWindow(window: PlatformRect?) {
        scanWindow = window
        mechanism?.setScanWindow(window)
    }

    override suspend fun analyzeImage(path: String): List<PlatformBarcode> {
        val context = applicationContext
            ?: throw FlutterError("not_running", "the plugin is not attached", null)
        val file = File(path)
        if (!file.isFile) {
            throw FlutterError("invalid_image", "no image file at $path", null)
        }
        val scanner = BarcodeMapping.options(scannerConfig.formats)
            ?.let { BarcodeScanning.getClient(it) }
            ?: BarcodeScanning.getClient()
        try {
            val image = withContext(Dispatchers.IO) {
                InputImage.fromFilePath(context, Uri.fromFile(file))
            }
            val barcodes = suspendCancellableCoroutine<List<Barcode>> { continuation ->
                scanner.process(image)
                    .addOnSuccessListener { results ->
                        if (continuation.isActive) {
                            continuation.resume(results)
                        }
                    }
                    .addOnFailureListener { error ->
                        if (continuation.isActive) {
                            continuation.resumeWithException(error)
                        }
                    }
            }
            return barcodes.mapNotNull(BarcodeMapping::map)
        } catch (error: Exception) {
            throw FlutterError(
                "analyze_failed",
                error.message ?: "image analysis failed",
                null,
            )
        } finally {
            scanner.close()
        }
    }

    override suspend fun dispose() = mutex.withLock {
        val current = mechanism
        mechanism = null
        if (current != null) {
            suspendCancellableCoroutine { continuation ->
                current.dispose {
                    if (continuation.isActive) {
                        continuation.resume(Unit)
                    }
                }
            }
        }
        // The texture is engine-scoped, not controller-scoped: a newer
        // controller's warm-up may have fetched its id moments before this
        // dispose landed in the call order (screen-switch spam does exactly
        // that). Releasing it here would fail the newer drive with
        // `configure_failed: preview surface is not available`; it is
        // released when the engine detaches instead.
    }

    private fun ensureMechanism(): CameraMechanism? {
        mechanism?.let { return it }
        val context = applicationContext ?: return null
        val api = flutterApi ?: return null
        val config = scannerConfig
        val created = CameraMechanism(
            context = context,
            previewSurface = { surface },
            onPreviewSize = { width, height ->
                entry?.surfaceTexture()?.setDefaultBufferSize(width, height)
            },
            onStateChanged = { snapshot ->
                lastState = snapshot.state
                scope.launch { api.onStateChanged(snapshot) }
            },
            onBarcodes = { barcodes ->
                scope.launch { api.onBarcodes(barcodes) }
            },
            selection = { selection },
            formats = config.formats,
            detectionSpeed = config.detectionSpeed,
            detectionTimeoutMs = config.detectionTimeoutMs.toInt(),
            initialScanWindow = scanWindow,
            invertImage = config.invertImage,
            initialTorch = config.torchEnabled,
            initialZoom = config.initialZoom,
            targetWidth = config.targetWidth?.toInt(),
            targetHeight = config.targetHeight?.toInt(),
        )
        mechanism = created
        return created
    }

    // --- Permissions -------------------------------------------------------

    private suspend fun ensureCameraPermission(): Boolean {
        val context = applicationContext ?: return false
        if (context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        val host = activity ?: return false
        return suspendCancellableCoroutine { continuation ->
            permissionResume = { granted ->
                if (continuation.isActive) {
                    continuation.resume(granted)
                }
            }
            continuation.invokeOnCancellation { permissionResume = null }
            Handler(Looper.getMainLooper()).post {
                if (continuation.isActive) {
                    host.requestPermissions(
                        arrayOf(Manifest.permission.CAMERA),
                        PERMISSION_REQUEST_CODE,
                    )
                }
            }
        }
    }

    // --- ActivityAware -----------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
    }

    private fun attachActivity(host: Activity) {
        detachActivity()
        activity = host
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStopped(stopped: Activity) {
                if (stopped !== host) {
                    return
                }
                // Close deliberately instead of waiting for the OS to revoke
                // camera access in the background. The close joins the same
                // mutex queue as pigeon calls: firing it directly would
                // retarget an in-flight drive and complete its caller with
                // `closed`, which apps model as a failure even though the
                // ordering was not caused by anything they did.
                scope.launch {
                    mutex.withLock {
                        mechanism?.driveTo(PlatformState.CLOSED) { }
                    }
                }
            }

            override fun onActivityCreated(a: Activity, b: Bundle?) {}

            override fun onActivityStarted(a: Activity) {}

            override fun onActivityResumed(a: Activity) {}

            override fun onActivityPaused(a: Activity) {}

            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}

            override fun onActivityDestroyed(a: Activity) {}
        }
        host.application.registerActivityLifecycleCallbacks(callbacks)
        lifecycleCallbacks = callbacks
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionListener)
        activityBinding = null
        val callbacks = lifecycleCallbacks
        val host = activity
        if (callbacks != null && host != null) {
            host.application.unregisterActivityLifecycleCallbacks(callbacks)
        }
        lifecycleCallbacks = null
        activity = null
    }

    private fun releaseTexture() {
        try {
            surface?.release()
        } catch (_: Throwable) {
        }
        surface = null
        try {
            entry?.release()
        } catch (_: Throwable) {
        }
        entry = null
    }
}

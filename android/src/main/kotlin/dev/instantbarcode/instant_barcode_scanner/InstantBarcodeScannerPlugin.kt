package dev.instantbarcode.instant_barcode_scanner

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.view.Surface
import dev.instantbarcode.instant_barcode_scanner.pigeon.FlutterError
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCapabilities
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformSnapshot
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformState
import dev.instantbarcode.instant_barcode_scanner.pigeon.ScannerFlutterApi
import dev.instantbarcode.instant_barcode_scanner.pigeon.ScannerHostApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.view.TextureRegistry
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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
    private var registry: TextureRegistry? = null
    private var applicationContext: Context? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var mechanism: CameraMechanism? = null
    private var flutterApi: ScannerFlutterApi? = null
    private var activity: Activity? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null
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
        scope.cancel()
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

    override suspend fun getCapabilities(): PlatformCapabilities = PlatformCapabilities(
        supportsPark = true,
        supportsTrueClose = true,
    )

    override suspend fun driveTo(target: PlatformState): PlatformSnapshot {
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
        // The close contract of §9: a closed snapshot means the device object
        // is gone, and completion additionally means the camera HAL reports
        // the camera available again — safe to hand over to NFC.
        if (target == PlatformState.CLOSED && snapshot.state == PlatformState.CLOSED) {
            val context = applicationContext
            if (context != null) {
                awaitCameraAvailable(context)
            }
        }
        return snapshot
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
        val created = CameraMechanism(
            context = context,
            previewSurface = { surface },
            onPreviewSize = { width, height ->
                entry?.surfaceTexture()?.setDefaultBufferSize(width, height)
            },
            onStateChanged = { snapshot ->
                scope.launch { api.onStateChanged(snapshot) }
            },
            onBarcodes = { barcodes ->
                scope.launch { api.onBarcodes(barcodes) }
            },
        )
        mechanism = created
        return created
    }

    // --- ActivityAware -----------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
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

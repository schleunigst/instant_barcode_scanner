package dev.instantbarcode.instant_barcode_scanner

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Size
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCameraFacing
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformCameraLensType
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Camera lookups shared by the mechanism, the analysis pipeline, and the
 * plugin: which camera to open, which size to ask for, and when the camera
 * is actually free.
 */

/** Which camera the controller asked for. */
internal data class CameraSelection(
    val facing: PlatformCameraFacing,
    val lensType: PlatformCameraLensType,
)

/** Zoom range of a camera, in device zoom-ratio units. */
internal data class ZoomInfo(val min: Double, val max: Double)

/**
 * Resolve a facing/lens request to a camera id.
 *
 * Lens classes are ranked by the shortest available focal length: `wide` is
 * the shortest, `zoom` the longest, and `normal` the one closest to a typical
 * main camera (~4.3 mm). `any` keeps the system order. If the requested
 * facing does not exist we fall back to the back camera, then to any camera —
 * mirroring the v0.1 behaviour instead of failing the open.
 */
internal fun resolveCameraId(manager: CameraManager, selection: CameraSelection): String {
    data class Candidate(val id: String, val facing: PlatformCameraFacing, val focal: Float?)

    val candidates = manager.cameraIdList.mapNotNull { id ->
        try {
            val characteristics = manager.getCameraCharacteristics(id)
            val facing = when (characteristics.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_BACK -> PlatformCameraFacing.BACK
                CameraCharacteristics.LENS_FACING_FRONT -> PlatformCameraFacing.FRONT
                CameraCharacteristics.LENS_FACING_EXTERNAL -> PlatformCameraFacing.EXTERNAL
                else -> return@mapNotNull null
            }
            val focal = characteristics
                .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?.minOrNull()
            Candidate(id, facing, focal)
        } catch (_: Throwable) {
            null
        }
    }
    val sameFacing = candidates.filter { it.facing == selection.facing }
        .ifEmpty { candidates.filter { it.facing == PlatformCameraFacing.BACK } }
        .ifEmpty { candidates }
    require(sameFacing.isNotEmpty()) { "no camera is available" }
    if (selection.lensType == PlatformCameraLensType.ANY || sameFacing.size == 1) {
        return sameFacing.first().id
    }
    val byFocal = sameFacing.sortedBy { it.focal ?: Float.MAX_VALUE }
    return when (selection.lensType) {
        PlatformCameraLensType.WIDE -> byFocal.first().id
        PlatformCameraLensType.ZOOM -> byFocal.last().id
        PlatformCameraLensType.NORMAL ->
            byFocal.minByOrNull { abs((it.focal ?: 4.3f) - 4.3f) }?.id
                ?: byFocal.first().id
        PlatformCameraLensType.ANY -> sameFacing.first().id
    }
}

/** The back camera, or the first camera if there is no back-facing one. */
internal fun backCameraId(manager: CameraManager): String {
    return manager.cameraIdList.firstOrNull { id ->
        manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_BACK
    } ?: manager.cameraIdList.first()
}

/** Zoom range for a camera, preferring the API 30+ zoom-ratio range. */
internal fun zoomInfo(characteristics: CameraCharacteristics): ZoomInfo {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        val range = characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
        if (range != null && range.upper > range.lower) {
            return ZoomInfo(range.lower.toDouble(), range.upper.toDouble())
        }
    }
    val maxDigital = characteristics
        .get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
        ?: 1f
    return ZoomInfo(1.0, maxDigital.toDouble().coerceAtLeast(1.0))
}

/** Largest size within the budget, else the first one offered. */
internal fun bestSize(
    sizes: Array<Size>,
    maxWidth: Int = 1280,
    maxHeight: Int = 720,
): Size {
    return sizes.filter { it.width <= maxWidth && it.height <= maxHeight }
        .maxByOrNull { it.width * it.height } ?: sizes.first()
}

/** Sensor orientation, defaulting to 90 when the device does not report one. */
internal fun sensorOrientation(characteristics: CameraCharacteristics): Int =
    characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

/**
 * Watch for the camera device to become available again.
 *
 * Registration must happen *before* closing the camera: availability
 * callbacks report transitions only and do not replay the current state, so a
 * watcher created after the close can miss the release and wait out the full
 * timeout. Start one before the close drive and await it afterwards.
 */
internal class CameraAvailabilityWatch(context: Context, cameraId: String) {
    private val manager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val executor = Executors.newSingleThreadExecutor()
    private val available = CompletableDeferred<Unit>()

    private val callback = object : CameraManager.AvailabilityCallback() {
        override fun onCameraAvailable(availableId: String) {
            if (availableId == cameraId) {
                available.complete(Unit)
            }
        }
    }

    fun start() {
        manager.registerAvailabilityCallback(executor, callback)
    }

    suspend fun await(timeoutMs: Long = 1000) {
        if (available.isCompleted) {
            return
        }
        withTimeoutOrNull(timeoutMs) { available.await() }
    }

    fun close() {
        manager.unregisterAvailabilityCallback(callback)
        executor.shutdown()
    }
}

/**
 * Wait for the camera manager to report [cameraId] available. Prefer
 * [CameraAvailabilityWatch] when the close call is still ahead: this helper
 * registers after the fact and cannot observe a release that already
 * happened.
 */
internal suspend fun awaitCameraAvailable(
    context: Context,
    cameraId: String = backCameraId(
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager,
    ),
    timeoutMs: Long = 1000,
) {
    val watch = CameraAvailabilityWatch(context, cameraId)
    watch.start()
    try {
        watch.await(timeoutMs)
    } finally {
        watch.close()
    }
}

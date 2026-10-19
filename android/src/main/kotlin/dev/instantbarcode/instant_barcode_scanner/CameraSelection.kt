package dev.instantbarcode.instant_barcode_scanner

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Size
import java.util.concurrent.Executors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Camera lookups shared by the mechanism, the analysis pipeline, and the
 * plugin: which camera to open, which size to ask for, and when the camera
 * is actually free.
 */

/** The back camera, or the first camera if there is no back-facing one. */
internal fun backCameraId(manager: CameraManager): String {
    return manager.cameraIdList.firstOrNull { id ->
        manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_BACK
    } ?: manager.cameraIdList.first()
}

/** Largest size within the 1280x720 budget, else the first one offered. */
internal fun bestSize(sizes: Array<Size>): Size {
    return sizes.filter { it.width <= 1280 && it.height <= 720 }
        .maxByOrNull { it.width * it.height } ?: sizes.first()
}

/** Sensor orientation, defaulting to 90 when the device does not report one. */
internal fun sensorOrientation(characteristics: CameraCharacteristics): Int =
    characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

/**
 * Wait for the CameraManager to report the back camera available. The
 * callback fires immediately with the current state, so after a truthful
 * close this returns fast (~0.19 s measured on the target device) and a
 * host can open an NFC reader straight away.
 */
internal suspend fun awaitCameraAvailable(context: Context, timeoutMs: Long = 1000) {
    val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    val cameraId = try {
        backCameraId(manager)
    } catch (t: Throwable) {
        return
    }
    val available = CompletableDeferred<Unit>()
    val executor = Executors.newSingleThreadExecutor()
    val callback = object : CameraManager.AvailabilityCallback() {
        override fun onCameraAvailable(availableId: String) {
            if (availableId == cameraId) {
                available.complete(Unit)
            }
        }
    }
    manager.registerAvailabilityCallback(executor, callback)
    try {
        withTimeoutOrNull(timeoutMs) { available.await() }
    } finally {
        manager.unregisterAvailabilityCallback(callback)
        executor.shutdown()
    }
}

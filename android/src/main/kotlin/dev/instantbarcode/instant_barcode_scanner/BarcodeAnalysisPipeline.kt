package dev.instantbarcode.instant_barcode_scanner

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcodeFormat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The ML Kit half of the mechanism: one ImageReader target, one decoder, one
 * worker thread. Lives and dies with the mechanism.
 *
 * The mechanism marks the pipeline live when repeating starts
 * ([newGeneration]) and answers [isLive] from its own state. In-flight
 * results tagged with an older generation, or arriving while not live, are
 * dropped — a decode that completes after `park`/`close` never resurfaces as
 * a fresh read.
 *
 * Barcode batches are delivered on the main thread.
 *
 * @param isLive reads the mechanism's streaming state; called on the analysis
 *   thread.
 * @param onBarcodes decoded barcode batches, main thread.
 */
internal class BarcodeAnalysisPipeline(
    private val context: Context,
    private val isLive: () -> Boolean,
    private val onBarcodes: (List<PlatformBarcode>) -> Unit,
) {
    companion object {
        private const val TAG = "InstantScanner"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private val thread = HandlerThread("ibs-analysis").apply { start() }
    private val handler = Handler(thread.looper)

    private var reader: ImageReader? = null
    @Volatile private var scanner: BarcodeScanner? = null
    private val busy = AtomicBoolean(false)

    /**
     * Bumped every time repeating actually starts. Results tagged with an
     * older generation are dropped.
     */
    @Volatile private var generation = 0L

    /** The analysis surface, created on first use; idempotent. */
    fun target(sensorRotation: Int): Surface {
        reader?.let { return it.surface }
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = backCameraId(manager)
        val map = manager.getCameraCharacteristics(camId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        val size = bestSize(map.getOutputSizes(ImageFormat.YUV_420_888))
        val newReader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 3)
        newReader.setOnImageAvailableListener({ rd -> onImageAvailable(rd, sensorRotation) }, handler)
        scannerInstance()
        reader = newReader
        return newReader.surface
    }

    /** Repeating just started; anything decoded from before is stale. */
    fun newGeneration() {
        generation++
    }

    fun shutdown() {
        try {
            reader?.close()
        } catch (_: Throwable) {
        }
        reader = null
        try {
            scanner?.close()
        } catch (_: Throwable) {
        }
        scanner = null
        thread.quitSafely()
    }

    /** Camera thread only. Reader and scanner are created and closed together. */
    private fun scannerInstance(): BarcodeScanner {
        return scanner ?: BarcodeScanning.getClient().also { scanner = it }
    }

    private fun onImageAvailable(rd: ImageReader, sensorRotation: Int) {
        var image: android.media.Image? = null
        try {
            image = rd.acquireLatestImage()
        } catch (_: Throwable) {
        }
        val img = image ?: return
        if (!busy.compareAndSet(false, true)) {
            img.close()
            return
        }
        val captured = generation
        try {
            val input = InputImage.fromMediaImage(img, sensorRotation)
            val task = scannerInstance().process(input)
            task.addOnSuccessListener { barcodes ->
                if (!isLive() || captured != generation) {
                    return@addOnSuccessListener
                }
                val mapped = barcodes.mapNotNull(::mapBarcode)
                if (mapped.isNotEmpty() && isLive() && captured == generation) {
                    mainHandler.post { onBarcodes(mapped) }
                }
            }.addOnCompleteListener {
                img.close()
                busy.set(false)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "analyzer error", t)
            img.close()
            busy.set(false)
        }
    }

    private fun mapBarcode(barcode: Barcode): PlatformBarcode? {
        val rawBytes = barcode.rawBytes
        val text = barcode.rawValue
        if (rawBytes == null && text == null) {
            return null
        }
        return PlatformBarcode(mapFormat(barcode.format), rawBytes, text)
    }

    private fun mapFormat(format: Int): PlatformBarcodeFormat {
        return when (format) {
            Barcode.FORMAT_AZTEC -> PlatformBarcodeFormat.AZTEC
            Barcode.FORMAT_CODABAR -> PlatformBarcodeFormat.CODABAR
            Barcode.FORMAT_CODE_39 -> PlatformBarcodeFormat.CODE39
            Barcode.FORMAT_CODE_93 -> PlatformBarcodeFormat.CODE93
            Barcode.FORMAT_CODE_128 -> PlatformBarcodeFormat.CODE128
            Barcode.FORMAT_DATA_MATRIX -> PlatformBarcodeFormat.DATA_MATRIX
            Barcode.FORMAT_EAN_8 -> PlatformBarcodeFormat.EAN8
            Barcode.FORMAT_EAN_13 -> PlatformBarcodeFormat.EAN13
            Barcode.FORMAT_ITF -> PlatformBarcodeFormat.ITF
            Barcode.FORMAT_PDF417 -> PlatformBarcodeFormat.PDF417
            Barcode.FORMAT_QR_CODE -> PlatformBarcodeFormat.QR_CODE
            Barcode.FORMAT_UPC_A -> PlatformBarcodeFormat.UPC_A
            Barcode.FORMAT_UPC_E -> PlatformBarcodeFormat.UPC_E
            else -> PlatformBarcodeFormat.UNKNOWN
        }
    }
}

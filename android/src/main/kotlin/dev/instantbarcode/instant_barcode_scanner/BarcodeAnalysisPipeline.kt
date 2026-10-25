package dev.instantbarcode.instant_barcode_scanner

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcodeFormat
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformDetectionSpeed
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformRect
import java.nio.ByteBuffer
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
    private val formats: List<PlatformBarcodeFormat>,
    private val detectionSpeed: PlatformDetectionSpeed,
    private val detectionTimeoutMs: Long,
    initialScanWindow: PlatformRect?,
    private val invertImage: Boolean,
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
    private var readerCameraId: String? = null
    private var readerMaxWidth = 0
    private var readerMaxHeight = 0
    @Volatile private var scanner: BarcodeScanner? = null
    private val busy = AtomicBoolean(false)

    /** Last frame actually analyzed; gates `normal` mode. */
    @Volatile private var lastAnalysisAt = 0L

    /** Last reported raw-value set; gates `noDuplicates` mode. */
    @Volatile private var lastRawValues: List<String?>? = null

    /** Restriction in normalized upright coordinates; null decodes everywhere. */
    @Volatile private var scanWindow: PlatformRect? = initialScanWindow

    @Volatile private var imageRotation = 0
    @Volatile private var frameWidth = 0
    @Volatile private var frameHeight = 0

    fun setScanWindow(window: PlatformRect?) {
        scanWindow = window
    }

    /**
     * Bumped every time repeating actually starts. Results tagged with an
     * older generation are dropped.
     */
    @Volatile private var generation = 0L

    /**
     * The analysis surface, created on first use; idempotent per camera and
     * size budget. Switching camera (or resolution) rebuilds the reader, so
     * frames never keep flowing from a stale configuration.
     */
    @Synchronized
    fun target(
        sensorRotation: Int,
        cameraId: String,
        maxWidth: Int,
        maxHeight: Int,
    ): Surface {
        reader?.let { existing ->
            if (readerCameraId == cameraId &&
                readerMaxWidth == maxWidth &&
                readerMaxHeight == maxHeight
            ) {
                return existing.surface
            }
            try {
                existing.close()
            } catch (_: Throwable) {
            }
            reader = null
        }
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val map = manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        val size = bestSize(
            map.getOutputSizes(ImageFormat.YUV_420_888),
            maxWidth,
            maxHeight,
        )
        val newReader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 3)
        newReader.setOnImageAvailableListener({ rd -> onImageAvailable(rd, sensorRotation) }, handler)
        imageRotation = sensorRotation
        frameWidth = size.width
        frameHeight = size.height
        scannerInstance()
        reader = newReader
        readerCameraId = cameraId
        readerMaxWidth = maxWidth
        readerMaxHeight = maxHeight
        return newReader.surface
    }

    /** Repeating just started; anything decoded from before is stale. */
    fun newGeneration() {
        generation++
        lastAnalysisAt = 0L
        lastRawValues = null
    }

    fun shutdown() {
        try {
            reader?.close()
        } catch (_: Throwable) {
        }
        reader = null
        readerCameraId = null
        // scannerInstance() is synchronized on this; shut the client down under
        // the same lock so a concurrent lazy creation cannot race the close and
        // leak one client.
        val currentScanner = synchronized(this) {
            val current = scanner
            scanner = null
            current
        }
        try {
            currentScanner?.close()
        } catch (_: Throwable) {
        }
        thread.quitSafely()
    }

    /**
     * Camera thread and analysis thread both reach this (session setup and
     * frame processing); make the lazy creation atomic or two clients are
     * created and one is leaked.
     */
    @Synchronized
    private fun scannerInstance(): BarcodeScanner {
        scanner?.let { return it }
        val created = BarcodeMapping.options(formats)?.let { options ->
            BarcodeScanning.getClient(options)
        } ?: BarcodeScanning.getClient()
        scanner = created
        return created
    }

    private fun onImageAvailable(rd: ImageReader, sensorRotation: Int) {
        var image: android.media.Image? = null
        try {
            image = rd.acquireLatestImage()
        } catch (_: Throwable) {
        }
        val img = image ?: return
        val now = SystemClock.elapsedRealtime()
        if (detectionSpeed == PlatformDetectionSpeed.NORMAL &&
            now - lastAnalysisAt < detectionTimeoutMs
        ) {
            img.close()
            return
        }
        if (!busy.compareAndSet(false, true)) {
            img.close()
            return
        }
        if (detectionSpeed == PlatformDetectionSpeed.NORMAL) {
            lastAnalysisAt = now
        }
        val captured = generation
        try {
            val input = if (invertImage) {
                val nv21 = invertedNv21(img)
                InputImage.fromByteBuffer(
                    ByteBuffer.wrap(nv21),
                    img.width,
                    img.height,
                    sensorRotation,
                    InputImage.IMAGE_FORMAT_NV21,
                )
            } else {
                InputImage.fromMediaImage(img, sensorRotation)
            }
            val task = scannerInstance().process(input)
            task.addOnSuccessListener { barcodes ->
                if (!isLive() || captured != generation) {
                    return@addOnSuccessListener
                }
                if (detectionSpeed == PlatformDetectionSpeed.NO_DUPLICATES) {
                    val values = barcodes.mapNotNull { it.rawValue }.sorted()
                    if (values == lastRawValues) {
                        return@addOnSuccessListener
                    }
                    if (values.isNotEmpty()) {
                        lastRawValues = values
                    }
                }
                val mapped = barcodes.mapNotNull(BarcodeMapping::map)
                val window = scanWindow
                val visible = if (window == null) {
                    mapped
                } else {
                    mapped.filter { isInsideWindow(it, window) }
                }
                if (visible.isNotEmpty() && isLive() && captured == generation) {
                    mainHandler.post { onBarcodes(visible) }
                }
            }.addOnCompleteListener {
                // A reader closed during an in-flight decode makes close()
                // throw; never let that escape the callback.
                try {
                    img.close()
                } catch (_: Throwable) {
                }
                busy.set(false)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "analyzer error", t)
            try {
                img.close()
            } catch (_: Throwable) {
            }
            busy.set(false)
        }
    }

    /**
     * Copy the YUV frame into inverted NV21 bytes. Inverting Y, U and V is
     * equivalent to inverting RGB: luma flips and chroma mirrors around 128.
     * Needed because ML Kit cannot decode from a YUV frame directly once the
     * bytes are transformed.
     */
    private fun invertedNv21(image: android.media.Image): ByteArray {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val out = ByteArray(ySize + ySize / 2)
        val planes = image.planes

        val yPlane = planes[0]
        var position = 0
        for (row in 0 until height) {
            yPlane.buffer.position(row * yPlane.rowStride)
            yPlane.buffer.get(out, position, width)
            position += width
        }

        val uPlane = planes[1]
        val vPlane = planes[2]
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            for (col in 0 until chromaWidth) {
                out[position++] = vPlane.buffer.get(row * vPlane.rowStride + col * vPlane.pixelStride)
                out[position++] = uPlane.buffer.get(row * uPlane.rowStride + col * uPlane.pixelStride)
            }
        }
        for (i in out.indices) {
            out[i] = (255 - (out[i].toInt() and 0xFF)).toByte()
        }
        return out
    }

    private fun isInsideWindow(barcode: PlatformBarcode, window: PlatformRect): Boolean {
        val corners = barcode.corners
        if (corners.isNullOrEmpty()) {
            return false
        }
        val rotation = imageRotation
        val width = if (rotation % 180 == 0) frameWidth else frameHeight
        val height = if (rotation % 180 == 0) frameHeight else frameWidth
        if (width <= 0 || height <= 0) {
            return false
        }
        val left = window.left * width
        val top = window.top * height
        val right = window.right * width
        val bottom = window.bottom * height
        return corners.all { it.x >= left && it.x <= right && it.y >= top && it.y <= bottom }
    }
}

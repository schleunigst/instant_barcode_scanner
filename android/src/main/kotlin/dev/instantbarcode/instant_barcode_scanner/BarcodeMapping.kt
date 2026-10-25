package dev.instantbarcode.instant_barcode_scanner

import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcode
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcodeFormat
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformBarcodeValueType
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformPoint
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformRect

/** Translation between ML Kit's barcode model and the pigeon-facing model. */
internal object BarcodeMapping {
    /**
     * Analyzer options for [formats], or null when every format is unknown
     * (ML Kit then decodes everything).
     */
    fun options(formats: List<PlatformBarcodeFormat>): BarcodeScannerOptions? {
        val supported = formats.mapNotNull(::format).distinct()
        if (supported.isEmpty()) {
            return null
        }
        return BarcodeScannerOptions.Builder()
            .setBarcodeFormats(supported.first(), *supported.drop(1).toIntArray())
            .build()
    }

    fun map(barcode: Barcode): PlatformBarcode? {
        val rawBytes = barcode.rawBytes
        val text = barcode.rawValue
        if (rawBytes == null && text == null) {
            return null
        }
        val box = barcode.boundingBox?.let {
            PlatformRect(
                it.left.toDouble(),
                it.top.toDouble(),
                it.right.toDouble(),
                it.bottom.toDouble(),
            )
        }
        val corners = barcode.cornerPoints?.map {
            PlatformPoint(it.x.toDouble(), it.y.toDouble())
        }
        return PlatformBarcode(
            mapFormat(barcode.format),
            rawBytes,
            text,
            barcode.displayValue,
            mapValueType(barcode.valueType),
            box,
            corners,
        )
    }

    /** Map our format enum onto ML Kit's bitmask constants. */
    fun format(format: PlatformBarcodeFormat): Int? {
        return when (format) {
            PlatformBarcodeFormat.AZTEC -> Barcode.FORMAT_AZTEC
            PlatformBarcodeFormat.CODABAR -> Barcode.FORMAT_CODABAR
            PlatformBarcodeFormat.CODE39 -> Barcode.FORMAT_CODE_39
            PlatformBarcodeFormat.CODE93 -> Barcode.FORMAT_CODE_93
            PlatformBarcodeFormat.CODE128 -> Barcode.FORMAT_CODE_128
            PlatformBarcodeFormat.DATA_MATRIX -> Barcode.FORMAT_DATA_MATRIX
            PlatformBarcodeFormat.EAN8 -> Barcode.FORMAT_EAN_8
            PlatformBarcodeFormat.EAN13 -> Barcode.FORMAT_EAN_13
            PlatformBarcodeFormat.ITF -> Barcode.FORMAT_ITF
            PlatformBarcodeFormat.PDF417 -> Barcode.FORMAT_PDF417
            PlatformBarcodeFormat.QR_CODE -> Barcode.FORMAT_QR_CODE
            PlatformBarcodeFormat.UPC_A -> Barcode.FORMAT_UPC_A
            PlatformBarcodeFormat.UPC_E -> Barcode.FORMAT_UPC_E
            PlatformBarcodeFormat.UNKNOWN -> null
        }
    }

    fun mapFormat(format: Int): PlatformBarcodeFormat {
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

    fun mapValueType(valueType: Int): PlatformBarcodeValueType {
        return when (valueType) {
            Barcode.TYPE_CONTACT_INFO -> PlatformBarcodeValueType.CONTACT_INFO
            Barcode.TYPE_EMAIL -> PlatformBarcodeValueType.EMAIL
            Barcode.TYPE_ISBN -> PlatformBarcodeValueType.ISBN
            Barcode.TYPE_PHONE -> PlatformBarcodeValueType.PHONE
            Barcode.TYPE_PRODUCT -> PlatformBarcodeValueType.PRODUCT
            Barcode.TYPE_SMS -> PlatformBarcodeValueType.SMS
            Barcode.TYPE_TEXT -> PlatformBarcodeValueType.TEXT
            Barcode.TYPE_URL -> PlatformBarcodeValueType.URL
            Barcode.TYPE_WIFI -> PlatformBarcodeValueType.WIFI
            Barcode.TYPE_GEO -> PlatformBarcodeValueType.GEO
            Barcode.TYPE_CALENDAR_EVENT -> PlatformBarcodeValueType.CALENDAR_EVENT
            Barcode.TYPE_DRIVER_LICENSE -> PlatformBarcodeValueType.DRIVER_LICENSE
            else -> PlatformBarcodeValueType.UNKNOWN
        }
    }
}

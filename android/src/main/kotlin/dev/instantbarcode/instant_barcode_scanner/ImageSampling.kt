package dev.instantbarcode.instant_barcode_scanner

/**
 * Still-image decode budgeting.
 *
 * `analyzeImage` with `invertImage` decodes the file and then copies it into a
 * second ARGB_8888 bitmap, so a full-resolution phone photo (tens of
 * megapixels) would allocate hundreds of megabytes. These helpers are pure so
 * the allocation budget can be unit-tested off-device.
 */
internal object ImageSampling {
    /** Long-edge cap for the still image handed to ML Kit. */
    const val MAX_EDGE = 2048

    /**
     * Power-of-two sample factor for `BitmapFactory`, so the decoded long edge
     * is at most [maxEdge]. Returns 1 when the image already fits.
     */
    fun inSampleSize(width: Int, height: Int, maxEdge: Int = MAX_EDGE): Int {
        require(maxEdge > 0) { "maxEdge must be positive" }
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        var longest = maxOf(width, height)
        while (longest > maxEdge) {
            sample *= 2
            longest /= 2
        }
        return sample
    }

    /** Bytes an ARGB_8888 bitmap needs after sampling. */
    fun estimatedArgbBytes(width: Int, height: Int, sampleSize: Int): Long {
        require(sampleSize > 0) { "sampleSize must be positive" }
        return (width / sampleSize).toLong() * (height / sampleSize) * 4L
    }
}

package dev.instantbarcode.instant_barcode_scanner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageSamplingTest {
    @Test
    fun `caps a 200 MP image under 16 MiB`() {
        val width = 20000
        val height = 10000
        val sample = ImageSampling.inSampleSize(width, height)
        assertEquals(16, sample)
        val bytes = ImageSampling.estimatedArgbBytes(width, height, sample)
        assertTrue("sampled allocation was $bytes bytes", bytes <= 16L * 1024 * 1024)
        // The same image decoded at full resolution is ~763 MiB.
        assertTrue(
            ImageSampling.estimatedArgbBytes(width, height, 1) > 700L * 1024 * 1024,
        )
    }

    @Test
    fun `sample is a power of two and never shrinks below the cap`() {
        val sample = ImageSampling.inSampleSize(4096, 2048)
        assertEquals(2, sample)
        assertEquals(2048, 4096 / sample)
    }

    @Test
    fun `a small image is not sampled`() {
        assertEquals(1, ImageSampling.inSampleSize(1000, 800))
    }
}

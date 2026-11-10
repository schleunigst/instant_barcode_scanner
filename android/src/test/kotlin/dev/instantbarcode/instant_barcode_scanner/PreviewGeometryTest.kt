package dev.instantbarcode.instant_barcode_scanner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewGeometryTest {
    @Test
    fun `display rotation maps to clockwise degrees`() {
        assertEquals(0, PreviewGeometry.displayRotationDegrees(0))
        assertEquals(90, PreviewGeometry.displayRotationDegrees(1))
        assertEquals(180, PreviewGeometry.displayRotationDegrees(2))
        assertEquals(270, PreviewGeometry.displayRotationDegrees(3))
    }

    @Test
    fun `a sideways sensor swaps the upright size and keeps display rotation`() {
        val preview = PreviewGeometry.calculate(
            width = 1280,
            height = 720,
            sensorOrientation = 90,
            displayRotationDegrees = 90,
            mirrored = false,
        )
        assertEquals(720, preview.width)
        assertEquals(1280, preview.height)
        assertEquals(90, preview.rotationDegrees)
        assertFalse(preview.mirrored)
    }

    @Test
    fun `a zero sensor keeps the buffer size and ignores absent rotation`() {
        val preview = PreviewGeometry.calculate(
            width = 1280,
            height = 720,
            sensorOrientation = 0,
            displayRotationDegrees = PreviewGeometry.displayRotationDegrees(0),
            mirrored = false,
        )
        assertEquals(1280, preview.width)
        assertEquals(720, preview.height)
        assertEquals(0, preview.rotationDegrees)
    }

    @Test
    fun `front camera previews are mirrored`() {
        assertTrue(
            PreviewGeometry.calculate(1280, 720, 270, 0, mirrored = true).mirrored,
        )
    }
}

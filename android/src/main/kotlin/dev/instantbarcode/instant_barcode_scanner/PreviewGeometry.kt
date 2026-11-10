package dev.instantbarcode.instant_barcode_scanner

/**
 * Preview geometry derived from the camera buffer and the display rotation.
 *
 * Pure so the rotation math can be unit-tested off-device. The rotation input
 * is the platform's `Surface.ROTATION_*` value (0..3), which the plugin reads
 * from the activity's own display.
 */
internal data class UprightPreview(
    val width: Int,
    val height: Int,
    val rotationDegrees: Int,
    val mirrored: Boolean,
)

internal object PreviewGeometry {
    /** Upright buffer size; the sensor sits sideways on most phones. */
    fun uprightSize(width: Int, height: Int, sensorOrientation: Int): Pair<Int, Int> {
        val sideways = sensorOrientation % 180 == 90
        return if (sideways) height to width else width to height
    }

    fun calculate(
        width: Int,
        height: Int,
        sensorOrientation: Int,
        displayRotationDegrees: Int,
        mirrored: Boolean,
    ): UprightPreview {
        val (uprightWidth, uprightHeight) = uprightSize(width, height, sensorOrientation)
        return UprightPreview(
            width = uprightWidth,
            height = uprightHeight,
            rotationDegrees = displayRotationDegrees,
            mirrored = mirrored,
        )
    }

    /** Map `Surface.ROTATION_*` (0..3) to clockwise degrees. */
    fun displayRotationDegrees(surfaceRotation: Int): Int = when (surfaceRotation) {
        1 -> 90
        2 -> 180
        3 -> 270
        else -> 0
    }
}

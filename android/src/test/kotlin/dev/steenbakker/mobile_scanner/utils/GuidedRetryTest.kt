package dev.steenbakker.mobile_scanner.utils

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Unit tests for the helpers behind the still image retry of a barcode
 * that ML Kit located without decoding it.
 */
internal class GuidedRetryTest {

    // ==========================================================================
    // guidedRetryCrop tests
    // ==========================================================================

    @Test
    fun guidedRetryCrop_expandsTheBoxAndScalesItToTheTargetWidth() {
        // A 600 px box gets a 90 px margin on each side and is scaled by 250 / 600.
        val crop = assertNotNull(guidedRetryCrop(200, 300, 800, 900, 1000, 1280))

        assertEquals(110, crop.left)
        assertEquals(210, crop.top)
        assertEquals(780, crop.width)
        assertEquals(780, crop.height)
        assertEquals(250.0 / 600.0, crop.scale, 1e-9)
        assertEquals(325, crop.scaledWidth)
        assertEquals(325, crop.scaledHeight)
    }

    @Test
    fun guidedRetryCrop_clampsTheMarginToTheImage() {
        val crop = assertNotNull(guidedRetryCrop(10, 20, 990, 1000, 1000, 1010))

        assertEquals(0, crop.left)
        assertEquals(0, crop.top)
        assertEquals(1000, crop.width)
        assertEquals(1010, crop.height)
    }

    @Test
    fun guidedRetryCrop_boxNotWiderThanTheTarget_returnsNull() {
        assertNull(guidedRetryCrop(100, 100, 350, 350, 1000, 1000))
        assertNull(guidedRetryCrop(100, 100, 300, 300, 1000, 1000))
    }

    @Test
    fun guidedRetryCrop_emptyBox_returnsNull() {
        assertNull(guidedRetryCrop(100, 100, 100, 500, 1000, 1000))
        assertNull(guidedRetryCrop(100, 100, 500, 100, 1000, 1000))
    }

    // ==========================================================================
    // barcodeInSourceCoordinates tests
    // ==========================================================================

    @Test
    fun barcodeInSourceCoordinates_movesCornersAndSizeBackToTheSourceImage() {
        val crop = GuidedRetryCrop(left = 110, top = 210, width = 780, height = 780, scale = 0.5)
        val barcode = mapOf(
            "rawValue" to "value",
            "corners" to listOf(
                mapOf("x" to 50.0, "y" to 50.0),
                mapOf("x" to 300.0, "y" to 50.0),
                mapOf("x" to 300.0, "y" to 300.0),
                mapOf("x" to 50.0, "y" to 300.0),
            ),
            "size" to mapOf("width" to 250.0, "height" to 250.0),
        )

        val result = barcodeInSourceCoordinates(barcode, crop)

        assertEquals("value", result["rawValue"])
        assertEquals(
            listOf(
                mapOf("x" to 210.0, "y" to 310.0),
                mapOf("x" to 710.0, "y" to 310.0),
                mapOf("x" to 710.0, "y" to 810.0),
                mapOf("x" to 210.0, "y" to 810.0),
            ),
            result["corners"],
        )
        assertEquals(mapOf("width" to 500.0, "height" to 500.0), result["size"])
    }

    @Test
    fun barcodeInSourceCoordinates_barcodeWithoutCornersOrSize_isUnchanged() {
        val crop = GuidedRetryCrop(left = 110, top = 210, width = 780, height = 780, scale = 0.5)
        val barcode = mapOf("rawValue" to "value", "corners" to null, "size" to emptyMap<String, Any?>())

        assertEquals(barcode, barcodeInSourceCoordinates(barcode, crop))
    }

    // ==========================================================================
    // flattenOnWhite tests
    // ==========================================================================

    @Test
    fun flattenOnWhite_replacesTransparencyWithWhite() {
        val pixels = intArrayOf(0x00000000, 0x80000000.toInt(), 0xFF123456.toInt())

        flattenOnWhite(pixels)

        assertContentEquals(
            intArrayOf(0xFFFFFFFF.toInt(), 0xFF7F7F7F.toInt(), 0xFF123456.toInt()),
            pixels,
        )
    }

    // ==========================================================================
    // gaussianBlur tests
    // ==========================================================================

    @Test
    fun gaussianBlur_uniformImage_staysUniform() {
        val pixels = IntArray(5 * 4) { 0xFF808080.toInt() }

        assertContentEquals(pixels, gaussianBlur(pixels, 5, 4, 1.0))
    }

    @Test
    fun gaussianBlur_spreadsAPixelEvenlyAroundItself() {
        val size = 9
        val centre = size / 2
        val pixels = IntArray(size * size) { 0xFF000000.toInt() }
        pixels[centre * size + centre] = 0xFFFFFFFF.toInt()

        val blurred = gaussianBlur(pixels, size, size, 1.0)
        fun red(x: Int, y: Int): Int = (blurred[y * size + x] shr 16) and 0xFF

        // The peak stays in the middle and falls off the same way in every direction.
        assertTrue(red(centre, centre) in 1..254)
        assertTrue(red(centre, centre) > red(centre + 1, centre))
        assertTrue(red(centre + 1, centre) > red(centre + 2, centre))
        assertEquals(red(centre + 1, centre), red(centre - 1, centre))
        assertEquals(red(centre + 1, centre), red(centre, centre + 1))
        assertEquals(red(centre + 1, centre), red(centre, centre - 1))

        // The blur moves brightness around without adding or removing any, up to rounding.
        val total = (0 until size).sumOf { y -> (0 until size).sumOf { x -> red(x, y) } }
        assertTrue(abs(total - 0xFF) <= size * size / 2)

        // Every pixel stays opaque.
        assertTrue(blurred.all { pixel -> pixel ushr 24 == 0xFF })
    }
}

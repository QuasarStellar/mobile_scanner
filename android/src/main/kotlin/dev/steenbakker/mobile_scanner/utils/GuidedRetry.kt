package dev.steenbakker.mobile_scanner.utils

import android.graphics.Bitmap
import android.os.Build
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The part of an image that is decoded again, and the scale it is drawn at. */
internal class GuidedRetryCrop(
    val left: Int,
    val top: Int,
    val width: Int,
    val height: Int,
    val scale: Double,
) {
    val scaledWidth: Int get() = max(1, (width * scale).roundToInt())
    val scaledHeight: Int get() = max(1, (height * scale).roundToInt())
}

// ML Kit locates a QR code with styled modules (rounded, merged with their neighbours) in a still
// image but returns no value for it. The code decodes once the styling is smoothed away, which
// takes a blur of about a quarter of a module. The width and blur below are tuned on a code of
// 61 modules; a code with far fewer or far more modules may need values of its own.
private const val TARGET_BOX_WIDTH = 250
private const val BLUR_SIGMA = 1.0

// Margin kept around the barcode box, as a fraction of the box size on each side.
private const val CROP_MARGIN = 0.15

/**
 * Returns the crop for a barcode box in an image of [imageWidth] x [imageHeight], scaled down
 * until the box is [TARGET_BOX_WIDTH] pixels wide, or null when the box is not wider than that.
 */
internal fun guidedRetryCrop(
    boxLeft: Int,
    boxTop: Int,
    boxRight: Int,
    boxBottom: Int,
    imageWidth: Int,
    imageHeight: Int,
): GuidedRetryCrop? {
    val boxWidth = boxRight - boxLeft
    val boxHeight = boxBottom - boxTop
    if (boxWidth <= 0 || boxHeight <= 0) return null
    // Enlarging adds no detail, and a box this small is not what the retry is for.
    if (boxWidth <= TARGET_BOX_WIDTH) return null

    val left = max(0, floor(boxLeft - boxWidth * CROP_MARGIN).toInt())
    val top = max(0, floor(boxTop - boxHeight * CROP_MARGIN).toInt())
    val right = min(imageWidth, ceil(boxRight + boxWidth * CROP_MARGIN).toInt())
    val bottom = min(imageHeight, ceil(boxBottom + boxHeight * CROP_MARGIN).toInt())
    if (right <= left || bottom <= top) return null

    return GuidedRetryCrop(left, top, right - left, bottom - top, TARGET_BOX_WIDTH.toDouble() / boxWidth)
}

/** Moves the corners and size of a barcode decoded from [crop] back into source image coordinates. */
internal fun barcodeInSourceCoordinates(
    barcode: Map<String, Any?>,
    crop: GuidedRetryCrop,
): Map<String, Any?> {
    val result = barcode.toMutableMap()

    (barcode["corners"] as? List<*>)?.let { corners ->
        result["corners"] = corners.map { corner ->
            val point = corner as? Map<*, *>
            val x = (point?.get("x") as? Number)?.toDouble()
            val y = (point?.get("y") as? Number)?.toDouble()
            if (x == null || y == null) corner
            else mapOf("x" to x / crop.scale + crop.left, "y" to y / crop.scale + crop.top)
        }
    }

    (barcode["size"] as? Map<*, *>)?.let { size ->
        val width = (size["width"] as? Number)?.toDouble()
        val height = (size["height"] as? Number)?.toDouble()
        if (width != null && height != null) {
            result["size"] = mapOf("width" to width / crop.scale, "height" to height / crop.scale)
        }
    }

    return result
}

/**
 * Draws [crop] of [source] at its scale on white and blurs it.
 *
 * The result is a new bitmap that the caller recycles; [source] is left untouched.
 */
internal fun renderGuidedRetryCrop(source: Bitmap, crop: GuidedRetryCrop): Bitmap {
    val temporaries = ArrayList<Bitmap>()

    try {
        var current = source
        // Pixels of a hardware bitmap cannot be read.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && current.config == Bitmap.Config.HARDWARE) {
            current = current.copy(Bitmap.Config.ARGB_8888, false)
            temporaries.add(current)
        }

        // Both calls return their input when nothing changes, so only new bitmaps are recycled.
        val cropped = Bitmap.createBitmap(current, crop.left, crop.top, crop.width, crop.height)
        if (cropped !== current) temporaries.add(cropped)
        val scaled = Bitmap.createScaledBitmap(cropped, crop.scaledWidth, crop.scaledHeight, true)
        if (scaled !== cropped) temporaries.add(scaled)

        val width = scaled.width
        val height = scaled.height
        val pixels = IntArray(width * height)
        scaled.getPixels(pixels, 0, width, 0, 0, width, height)
        flattenOnWhite(pixels)

        return Bitmap.createBitmap(
            gaussianBlur(pixels, width, height, BLUR_SIGMA),
            width,
            height,
            Bitmap.Config.ARGB_8888,
        )
    } finally {
        for (bitmap in temporaries) {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }
}

/** Replaces transparency with white: transparent pixels would otherwise read as black. */
internal fun flattenOnWhite(pixels: IntArray) {
    for (index in pixels.indices) {
        val pixel = pixels[index]
        val alpha = pixel ushr 24
        if (alpha == 0xFF) continue

        val red = ((pixel shr 16) and 0xFF) * alpha / 0xFF + (0xFF - alpha)
        val green = ((pixel shr 8) and 0xFF) * alpha / 0xFF + (0xFF - alpha)
        val blue = (pixel and 0xFF) * alpha / 0xFF + (0xFF - alpha)
        pixels[index] = (0xFF shl 24) or (red shl 16) or (green shl 8) or blue
    }
}

/**
 * Blurs opaque ARGB [pixels] of a [width] x [height] image with a Gaussian of [sigma] pixels.
 *
 * The edge pixels are repeated outwards, so the image does not darken towards its border.
 */
internal fun gaussianBlur(pixels: IntArray, width: Int, height: Int, sigma: Double): IntArray {
    val radius = max(1, ceil(sigma * 3.0).toInt())
    val kernel = FloatArray(2 * radius + 1)
    var kernelSum = 0.0
    for (offset in -radius..radius) {
        val weight = exp(-(offset * offset) / (2.0 * sigma * sigma))
        kernel[offset + radius] = weight.toFloat()
        kernelSum += weight
    }
    for (index in kernel.indices) kernel[index] = (kernel[index] / kernelSum).toFloat()

    // Horizontal pass into float channels, then vertical pass back into packed pixels.
    val red = FloatArray(width * height)
    val green = FloatArray(width * height)
    val blue = FloatArray(width * height)
    for (y in 0 until height) {
        val row = y * width
        for (x in 0 until width) {
            var r = 0f
            var g = 0f
            var b = 0f
            for (offset in -radius..radius) {
                val pixel = pixels[row + min(width - 1, max(0, x + offset))]
                val weight = kernel[offset + radius]
                r += weight * ((pixel shr 16) and 0xFF)
                g += weight * ((pixel shr 8) and 0xFF)
                b += weight * (pixel and 0xFF)
            }
            red[row + x] = r
            green[row + x] = g
            blue[row + x] = b
        }
    }

    val output = IntArray(width * height)
    for (y in 0 until height) {
        for (x in 0 until width) {
            var r = 0f
            var g = 0f
            var b = 0f
            for (offset in -radius..radius) {
                val index = min(height - 1, max(0, y + offset)) * width + x
                val weight = kernel[offset + radius]
                r += weight * red[index]
                g += weight * green[index]
                b += weight * blue[index]
            }
            output[y * width + x] =
                (0xFF shl 24) or (channel(r) shl 16) or (channel(g) shl 8) or channel(b)
        }
    }

    return output
}

private fun channel(value: Float): Int = min(0xFF, max(0, (value + 0.5f).toInt()))

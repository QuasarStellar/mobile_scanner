package dev.steenbakker.mobile_scanner

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Point
import android.graphics.Rect
import android.net.Uri
import com.google.android.gms.tasks.OnCompleteListener
import com.google.android.gms.tasks.OnFailureListener
import com.google.android.gms.tasks.OnSuccessListener
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.steenbakker.mobile_scanner.objects.MobileScannerErrorCodes
import io.flutter.view.TextureRegistry
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.Mockito
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/*
 * Unit tests for analyzing a still image, including the retry of a barcode
 * that ML Kit located without decoding it.
 *
 * ML Kit itself is mocked: the tests drive the listeners of its tasks by hand.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
internal class MobileScannerAnalyzeImageTest {

    /** A scanner whose `process` task is completed by the test. */
    private class FakeScan {
        val scanner: BarcodeScanner = Mockito.mock(BarcodeScanner::class.java)

        @Suppress("UNCHECKED_CAST")
        val task: Task<List<Barcode>> = Mockito.mock(Task::class.java) as Task<List<Barcode>>

        init {
            Mockito.`when`(scanner.process(Mockito.any(InputImage::class.java))).thenReturn(task)
            Mockito.`when`(task.addOnSuccessListener(Mockito.any())).thenReturn(task)
            Mockito.`when`(task.addOnFailureListener(Mockito.any())).thenReturn(task)
            Mockito.`when`(task.addOnCompleteListener(Mockito.any())).thenReturn(task)
        }

        /** Waits for the scan to start: the retry prepares its image on another thread. */
        fun awaitStart() {
            Mockito.verify(scanner, Mockito.timeout(TIMEOUT_MS)).process(Mockito.any(InputImage::class.java))
        }

        fun succeed(vararg barcodes: Barcode) {
            @Suppress("UNCHECKED_CAST")
            val listener = ArgumentCaptor.forClass(OnSuccessListener::class.java)
                as ArgumentCaptor<OnSuccessListener<in List<Barcode>>>
            Mockito.verify(task, Mockito.timeout(TIMEOUT_MS)).addOnSuccessListener(listener.capture())
            listener.value.onSuccess(barcodes.toList())
            complete()
        }

        fun fail(error: Exception) {
            val listener = ArgumentCaptor.forClass(OnFailureListener::class.java)
            Mockito.verify(task, Mockito.timeout(TIMEOUT_MS)).addOnFailureListener(listener.capture())
            listener.value.onFailure(error)
            complete()
        }

        private fun complete() {
            @Suppress("UNCHECKED_CAST")
            val listener = ArgumentCaptor.forClass(OnCompleteListener::class.java)
                as ArgumentCaptor<OnCompleteListener<List<Barcode>>>
            Mockito.verify(task, Mockito.timeout(TIMEOUT_MS)).addOnCompleteListener(listener.capture())
            listener.value.onComplete(task)
        }
    }

    private companion object {
        const val TIMEOUT_MS = 5000L
        const val IMAGE_WIDTH = 1000
        const val IMAGE_HEIGHT = 1280
    }

    private val firstScan = FakeScan()
    private val retryScan = FakeScan()
    private val scannerOptions: MutableList<BarcodeScannerOptions?> = mutableListOf()
    private val retryBitmaps: MutableList<Bitmap> = mutableListOf()
    private val firstPassOptions = BarcodeScannerOptions.Builder().enableAllPotentialBarcodes().build()
    private val retryOptions = BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()

    private var reported: List<Map<String, Any?>>? = null
    private var error: String? = null

    private fun createInputImage(bitmap: Bitmap?, rotationDegrees: Int = 0): InputImage {
        val inputImage = Mockito.mock(InputImage::class.java)

        Mockito.`when`(inputImage.bitmapInternal).thenReturn(bitmap)
        Mockito.`when`(inputImage.rotationDegrees).thenReturn(rotationDegrees)

        return inputImage
    }

    private fun createSourceBitmap(): Bitmap =
        Bitmap.createBitmap(IMAGE_WIDTH, IMAGE_HEIGHT, Bitmap.Config.ARGB_8888)

    private fun createBarcode(
        rawValue: String?,
        box: Rect?,
        rawBytes: ByteArray? = rawValue?.toByteArray(),
    ): Barcode {
        val barcode = Mockito.mock(Barcode::class.java)

        Mockito.`when`(barcode.rawValue).thenReturn(rawValue)
        Mockito.`when`(barcode.rawBytes).thenReturn(rawBytes)
        Mockito.`when`(barcode.boundingBox).thenReturn(box)
        Mockito.`when`(barcode.cornerPoints).thenReturn(
            box?.let {
                arrayOf(
                    Point(box.left, box.top),
                    Point(box.right, box.top),
                    Point(box.right, box.bottom),
                    Point(box.left, box.bottom),
                )
            },
        )

        return barcode
    }

    // A barcode that ML Kit located without decoding it: a position, an empty value.
    private fun createUndecodedBarcode(box: Rect): Barcode = createBarcode("", box, rawBytes = null)

    private fun analyzeImage(
        inputImage: InputImage = createInputImage(createSourceBitmap()),
        retry: Boolean = true,
        fileInputImageFactory: () -> InputImage = { inputImage },
    ) {
        val scans = mutableListOf(firstScan, retryScan)
        val mobileScanner = MobileScanner(
            Mockito.mock(Activity::class.java),
            Mockito.mock(TextureRegistry::class.java),
            { _: List<Map<String, Any?>>, _: ByteArray?, _: Int?, _: Int? -> },
            { _: String -> },
            Mockito.mock(DeviceOrientationListener::class.java),
            { options: BarcodeScannerOptions? ->
                scannerOptions.add(options)
                scans.removeAt(0).scanner
            },
            { _, _ -> Mockito.mock(InputImage::class.java) },
            { _, _ -> fileInputImageFactory() },
            { bitmap, _ ->
                retryBitmaps.add(bitmap)
                Mockito.mock(InputImage::class.java)
            },
        )

        mobileScanner.analyzeImage(
            Mockito.mock(Uri::class.java),
            firstPassOptions,
            if (retry) retryOptions else null,
            { barcodes -> reported = barcodes },
            { message -> error = message },
        )
    }

    @Test
    fun analyzeImage_invalidImage_reportsAnError() {
        analyzeImage(fileInputImageFactory = { throw IOException("Not an image") })

        assertEquals(MobileScannerErrorCodes.ANALYZE_IMAGE_NO_VALID_IMAGE_ERROR_MESSAGE, error)
        assertNull(reported)
        assertTrue(scannerOptions.isEmpty())
    }

    @Test
    fun analyzeImage_processingFails_reportsAnError() {
        analyzeImage()
        firstScan.fail(IllegalStateException("ML Kit failure"))

        assertEquals("ML Kit failure", error)
        assertNull(reported)
        Mockito.verify(firstScan.scanner).close()
    }

    @Test
    fun analyzeImage_withoutRetry_reportsEveryBarcode() {
        analyzeImage(retry = false)
        firstScan.succeed(
            createBarcode("first", Rect(100, 100, 300, 300)),
            createUndecodedBarcode(Rect(400, 400, 900, 900)),
        )

        assertEquals(listOf("first", ""), reported?.map { barcode -> barcode["rawValue"] })
        assertEquals(listOf(firstPassOptions), scannerOptions)
        Mockito.verify(firstScan.scanner).close()
    }

    @Test
    fun analyzeImage_decodedBarcode_isReportedWithoutUndecodedOnes() {
        analyzeImage()
        firstScan.succeed(
            createBarcode("first", Rect(100, 100, 300, 300)),
            createUndecodedBarcode(Rect(400, 400, 900, 900)),
        )

        assertEquals(listOf("first"), reported?.map { barcode -> barcode["rawValue"] })
        assertEquals(listOf(firstPassOptions), scannerOptions)
        Mockito.verify(firstScan.scanner).close()
    }

    @Test
    fun analyzeImage_barcodeWithOnlyRawBytes_isReported() {
        analyzeImage()
        firstScan.succeed(createBarcode(null, Rect(100, 100, 700, 700), rawBytes = byteArrayOf(1, 2)))

        assertEquals(1, reported?.size)
        assertEquals(listOf(firstPassOptions), scannerOptions)
    }

    @Test
    fun analyzeImage_noBarcode_reportsNothing() {
        analyzeImage()
        firstScan.succeed()

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertEquals(listOf(firstPassOptions), scannerOptions)
    }

    @Test
    fun analyzeImage_undecodedBarcode_isRetriedOnASmallerCrop() {
        analyzeImage()
        // The larger of the two located barcodes is retried: a 600 px box with a 90 px margin.
        firstScan.succeed(
            createUndecodedBarcode(Rect(40, 40, 340, 340)),
            createUndecodedBarcode(Rect(200, 300, 800, 900)),
        )

        retryScan.awaitStart()

        val retryBitmap = retryBitmaps.single()
        val scale = 250.0 / 600.0

        assertNull(reported)
        assertEquals(listOf(firstPassOptions, retryOptions), scannerOptions)
        assertEquals(325, retryBitmap.width)
        assertEquals(325, retryBitmap.height)

        // The barcode fills the middle of the crop, so it maps back onto the located box.
        retryScan.succeed(createBarcode("value", Rect(38, 38, 288, 288)))

        val barcode = reported!!.single()
        @Suppress("UNCHECKED_CAST")
        val corners = barcode["corners"] as List<Map<String, Double>>
        @Suppress("UNCHECKED_CAST")
        val size = barcode["size"] as Map<String, Double>

        assertEquals("value", barcode["rawValue"])
        assertEquals(110 + 38 / scale, corners.first()["x"]!!, 1e-6)
        assertEquals(210 + 38 / scale, corners.first()["y"]!!, 1e-6)
        assertEquals(110 + 288 / scale, corners[2]["x"]!!, 1e-6)
        assertEquals(210 + 288 / scale, corners[2]["y"]!!, 1e-6)
        assertEquals(250 / scale, size["width"]!!, 1e-6)
        assertEquals(250 / scale, size["height"]!!, 1e-6)
        assertTrue(retryBitmap.isRecycled)
        Mockito.verify(firstScan.scanner).close()
        Mockito.verify(retryScan.scanner).close()
    }

    @Test
    fun analyzeImage_retryFindsNothing_reportsNothing() {
        analyzeImage()
        firstScan.succeed(createUndecodedBarcode(Rect(200, 300, 800, 900)))
        retryScan.succeed()

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertNull(error)
        Mockito.verify(retryScan.scanner).close()
    }

    @Test
    fun analyzeImage_retryFails_reportsNothing() {
        analyzeImage()
        firstScan.succeed(createUndecodedBarcode(Rect(200, 300, 800, 900)))
        retryScan.fail(IllegalStateException("ML Kit failure"))

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertNull(error)
        Mockito.verify(retryScan.scanner).close()
    }

    @Test
    fun analyzeImage_smallUndecodedBarcode_isNotRetried() {
        analyzeImage()
        firstScan.succeed(createUndecodedBarcode(Rect(100, 100, 300, 300)))

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertEquals(listOf(firstPassOptions), scannerOptions)
    }

    @Test
    fun analyzeImage_imageWithoutBitmap_isNotRetried() {
        analyzeImage(createInputImage(bitmap = null))
        firstScan.succeed(createUndecodedBarcode(Rect(200, 300, 800, 900)))

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertEquals(listOf(firstPassOptions), scannerOptions)
    }

    @Test
    fun analyzeImage_rotatedImage_isNotRetried() {
        analyzeImage(createInputImage(createSourceBitmap(), rotationDegrees = 90))
        firstScan.succeed(createUndecodedBarcode(Rect(200, 300, 800, 900)))

        assertEquals(emptyList<Map<String, Any?>>(), reported)
        assertEquals(listOf(firstPassOptions), scannerOptions)
    }
}

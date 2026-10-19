package dev.instantbarcode.instant_barcode_scanner

import android.Manifest
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraManager
import android.view.Surface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformSnapshot
import dev.instantbarcode.instant_barcode_scanner.pigeon.PlatformState
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device tests for the convergence contract. These need a real camera (or an
 * emulator with one) and the CAMERA permission; run them with
 * `./gradlew :instant_barcode_scanner:connectedDebugAndroidTest` from
 * `example/android`, or via `flutter test integration_test` for the
 * Flutter-level flows.
 *
 * What is asserted here is exactly what the Dart layer cannot: that a
 * confirmed snapshot matches the physical camera, and that a retarget while
 * opening does not leave the device open.
 */
@RunWith(AndroidJUnit4::class)
class CameraMechanismDeviceTest {
    @get:Rule
    val cameraPermission: GrantPermissionRule =
        GrantPermissionRule.grant(Manifest.permission.CAMERA)

    private lateinit var context: Context
    private lateinit var texture: SurfaceTexture
    private lateinit var surface: Surface
    private lateinit var mechanism: CameraMechanism

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        texture = SurfaceTexture(0)
        surface = Surface(texture)
        mechanism = CameraMechanism(
            context = context,
            previewSurface = { surface },
            onPreviewSize = { width, height -> texture.setDefaultBufferSize(width, height) },
            onStateChanged = {},
            onBarcodes = {},
        )
    }

    @After
    fun tearDown() {
        val done = CountDownLatch(1)
        mechanism.dispose { done.countDown() }
        done.await(5, TimeUnit.SECONDS)
        surface.release()
        texture.release()
    }

    @Test
    fun warmUpConvergesToParkedThenCloseReleases() {
        val parked = awaitDrive(PlatformState.PARKED)
        assertEquals(PlatformState.PARKED, parked.state)
        assertNull(parked.errorCode)

        val closed = awaitDrive(PlatformState.CLOSED)
        assertEquals(PlatformState.CLOSED, closed.state)
        assertNull(closed.errorCode)
    }

    @Test
    fun closeWhileOpeningStillEndsClosed() {
        // Retarget mid-convergence: the close must win, whatever step the
        // open was in (R1).
        val opening = drive(PlatformState.PARKED)
        val closed = drive(PlatformState.CLOSED).get(10, TimeUnit.SECONDS)
        assertEquals(PlatformState.CLOSED, closed.state)

        // The superseded request completes with a confirmed snapshot too —
        // never with a future left hanging.
        val first = opening.get(10, TimeUnit.SECONDS)
        assertTrue(
            "superseded request must confirm a stable state, was ${first.state}",
            first.state == PlatformState.PARKED || first.state == PlatformState.CLOSED,
        )

        // And the device is really closed: driving to closed again settles
        // immediately with no error.
        assertEquals(PlatformState.CLOSED, awaitDrive(PlatformState.CLOSED).state)
    }

    @Test
    fun closeReportsCameraAvailable() {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = backCameraId(manager)
        val available = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val callback = object : CameraManager.AvailabilityCallback() {
            override fun onCameraAvailable(availableId: String) {
                if (availableId == cameraId) {
                    available.countDown()
                }
            }
        }
        assertEquals(PlatformState.PARKED, awaitDrive(PlatformState.PARKED).state)
        manager.registerAvailabilityCallback(executor, callback)
        try {
            assertEquals(PlatformState.CLOSED, awaitDrive(PlatformState.CLOSED).state)
            assertTrue(
                "camera must report available after a truthful close",
                available.await(3, TimeUnit.SECONDS),
            )
        } finally {
            manager.unregisterAvailabilityCallback(callback)
            executor.shutdown()
        }
    }

    @Test
    fun disposeDuringOpenFinishesAndReleases() {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = backCameraId(manager)
        drive(PlatformState.PARKED) // intentionally not awaited

        val done = CountDownLatch(1)
        mechanism.dispose { done.countDown() }
        assertTrue("dispose must complete even mid-open", done.await(10, TimeUnit.SECONDS))

        val available = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val callback = object : CameraManager.AvailabilityCallback() {
            override fun onCameraAvailable(availableId: String) {
                if (availableId == cameraId) {
                    available.countDown()
                }
            }
        }
        manager.registerAvailabilityCallback(executor, callback)
        try {
            assertTrue(
                "disposed mechanism must not hold the camera open",
                available.await(3, TimeUnit.SECONDS),
            )
        } finally {
            manager.unregisterAvailabilityCallback(callback)
            executor.shutdown()
        }
    }

    private fun drive(target: PlatformState): CompletableFuture<PlatformSnapshot> {
        val future = CompletableFuture<PlatformSnapshot>()
        mechanism.driveTo(target) { snapshot -> future.complete(snapshot) }
        return future
    }

    private fun awaitDrive(
        target: PlatformState,
        timeoutMs: Long = 10_000,
    ): PlatformSnapshot = drive(target).get(timeoutMs, TimeUnit.MILLISECONDS)
}

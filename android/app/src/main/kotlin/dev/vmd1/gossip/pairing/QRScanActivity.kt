package dev.vmd1.gossip.pairing

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.NotFoundException
import com.google.zxing.ReaderException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.launch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "QRScanActivity"

private val decodeHints = mapOf(
    DecodeHintType.TRY_HARDER to true,
    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
)

/**
 * Scans the other device's pairing QR. As soon as a code is read the screen changes to the pairing screen, which
 * only shows the safety code to type on the other device (and a Cancel button); when both sides have paired the
 * activity finishes with `RESULT_OK` so the caller can move on by itself.
 */
class QRScanActivity : ComponentActivity() {

    private var boundService: SyncForegroundService? = null
    private var serviceConnection: ServiceConnection? = null
    private val handledScan = AtomicBoolean(false)
    private lateinit var cameraExecutor: ExecutorService
    private var cameraProvider: ProcessCameraProvider? = null

    private var uiState by mutableStateOf<PairingUiState>(PairingUiState.Idle)
    private var cameraGranted by mutableStateOf(false)
    private var viewModelReady by mutableStateOf(false)

    private val viewModel: PairingViewModel by viewModels {
        val service = boundService ?: error("Service not bound yet")
        PairingViewModelFactory(
            service.transportManager(),
            TrustedDevicesStore.getInstance(applicationContext),
            service.rosterGossipManager()
        )
    }

    private val requestCameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        cameraGranted = granted
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        IdentityKeyStore.ensureInitialized(applicationContext)
        cameraExecutor = Executors.newSingleThreadExecutor()

        setContent {
            dev.vmd1.gossip.ui.theme.ConnectTheme {
                Surface(modifier = Modifier.fillMaxSize()) { Content() }
            }
        }

        bindTransportService()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            cameraGranted = true
        } else {
            requestCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    @Composable
    private fun Content() {
        val state = uiState
        when {
            !viewModelReady -> Centered { CircularProgressIndicator() }
            state is PairingUiState.Idle -> ScanScreen()
            state is PairingUiState.Discovering -> Centered {
                CircularProgressIndicator(modifier = Modifier.size(48.dp))
                Text("Looking for the other device…", style = MaterialTheme.typography.titleMedium)
                OutlinedButton(onClick = ::cancelAndClose) { Text("Cancel") }
            }
            state is PairingUiState.Handshaking -> Centered {
                Text("Enter this code on the other device", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                Text(state.code, fontSize = 48.sp, fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center)
                CircularProgressIndicator(modifier = Modifier.size(32.dp))
                OutlinedButton(onClick = ::cancelAndClose) { Text("Cancel") }
            }
            state is PairingUiState.Success -> Centered {
                Text("Paired with ${state.deviceName}", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            }
            state is PairingUiState.Failed -> Centered {
                Text("Pairing didn't work", style = MaterialTheme.typography.titleMedium)
                Text(state.reason, textAlign = TextAlign.Center)
                Button(onClick = { viewModel.cancel() }) { Text("Try again") }
                OutlinedButton(onClick = ::cancelAndClose) { Text("Cancel") }
            }
        }
    }

    @Composable
    private fun ScanScreen() {
        Box(modifier = Modifier.fillMaxSize()) {
            if (cameraGranted) {
                AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx -> PreviewView(ctx).also { startCamera(it) } })
                DisposableEffect(Unit) { onDispose { cameraProvider?.unbindAll() } }
            }
            Column(
                modifier = Modifier.align(Alignment.BottomCenter).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    if (cameraGranted) "Point the camera at the other device's QR code" else "Camera permission is required to scan a QR code.",
                    style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center
                )
                androidx.compose.material3.TextButton(onClick = {
                    startActivity(Intent(this@QRScanActivity, CodePairActivity::class.java))
                    cancelAndClose()
                }) { Text("Can't scan? Pair with a code") }
                OutlinedButton(onClick = ::cancelAndClose) { Text("Cancel") }
            }
        }
    }

    @Composable
    private fun Centered(body: @Composable () -> Unit) {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally
        ) { body() }
    }

    private fun cancelAndClose() {
        if (viewModelReady) viewModel.cancel()
        setResult(RESULT_CANCELED)
        finish()
    }

    private fun bindTransportService() {
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val local = binder as? SyncForegroundService.LocalBinder ?: return
                boundService = local.service()
                observeViewModel()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(Intent(this, SyncForegroundService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    private fun observeViewModel() {
        viewModelReady = true
        lifecycleScope.launch {
            viewModel.uiState.collect { state ->
                uiState = state
                // Back to ready after a failure cleared itself or was dismissed: allow scanning again.
                if (state is PairingUiState.Idle) handledScan.set(false)
                if (state is PairingUiState.Success) {
                    setResult(RESULT_OK)
                    finish()
                }
            }
        }
    }

    private fun startCamera(previewView: PreviewView) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val provider = cameraProviderFuture.get()
            cameraProvider = provider
            val preview = androidx.camera.core.Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val reader = QRCodeReader()

            // The pairing QR carries a few hundred bytes, so its modules are small: CameraX's 640x480 default analysis
            // size is too coarse for zxing to resolve them.
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(android.util.Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                        )
                        .build()
                )
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                processImageProxy(reader, imageProxy)
            }

            try {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.e(TAG, "CameraX bind failed", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    // zxing's finder-pattern detector tolerates the frame's actual rotation, so the Y plane is decoded as-is
    // rather than rotated to match the display — the same approach zxing's own Camera1-based callers used.
    private fun processImageProxy(reader: QRCodeReader, imageProxy: ImageProxy) {
        try {
            val plane = imageProxy.planes[0]
            val data = ByteArray(plane.buffer.remaining())
            plane.buffer.get(data)
            val source = PlanarYUVLuminanceSource(
                data, plane.rowStride, imageProxy.height,
                0, 0, imageProxy.width, imageProxy.height, false
            )
            val result = try {
                reader.decode(BinaryBitmap(HybridBinarizer(source)), decodeHints)
            } catch (e: NotFoundException) {
                // The global threshold copes better with a bright screen's glare than the local one on some frames.
                reader.decode(BinaryBitmap(GlobalHistogramBinarizer(source)), decodeHints)
            }
            if (handledScan.compareAndSet(false, true)) {
                runOnUiThread { viewModel.onQrScanned(result.text) }
            }
        } catch (e: ReaderException) {
            // No readable QR code in this frame (not found, or found but too blurry to decode) — expected while the
            // camera searches and focuses.
        } catch (e: Exception) {
            Log.w(TAG, "Barcode scan failed", e)
        } finally {
            reader.reset()
            imageProxy.close()
        }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }
}

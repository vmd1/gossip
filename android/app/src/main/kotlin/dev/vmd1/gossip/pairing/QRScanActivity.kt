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
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.launch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "QRScanActivity"

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

            val scannerOptions = BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build()
            val scanner = BarcodeScanning.getClient(scannerOptions)

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                processImageProxy(scanner, imageProxy)
            }

            try {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.e(TAG, "CameraX bind failed", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun processImageProxy(scanner: com.google.mlkit.vision.barcode.BarcodeScanner, imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }
        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        scanner.process(image)
            .addOnSuccessListener { barcodes ->
                val value = barcodes.firstOrNull { it.rawValue != null }?.rawValue
                if (value != null && handledScan.compareAndSet(false, true)) {
                    runOnUiThread { viewModel.onQrScanned(value) }
                }
            }
            .addOnFailureListener { e -> Log.w(TAG, "Barcode scan failed", e) }
            .addOnCompleteListener { imageProxy.close() }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }
}

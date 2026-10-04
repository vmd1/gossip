package dev.vmd1.gossip.pairing

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import dev.vmd1.gossip.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.service.SyncForegroundService
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "QRScanActivity"

/**
 * CameraX preview + ML Kit barcode scanning to read the Mac's pairing QR code, then
 * hands the decoded payload to [PairingViewModel] to resolve the peer over NSD and
 * run the Noise_IK handshake.
 */
class QRScanActivity : ComponentActivity() {

    private var boundService: SyncForegroundService? = null
    private var serviceConnection: ServiceConnection? = null
    private val handledScan = AtomicBoolean(false)
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var statusView: TextView

    private val viewModel: PairingViewModel by viewModels {
        val service = boundService ?: error("Service not bound yet")
        PairingViewModelFactory(
            service.transportManager(),
            TrustedDevicesStore.getInstance(applicationContext),
            service.rosterGossipManager()
        )
    }

    private val requestCameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else statusView.text = "Camera permission is required to scan a QR code."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        IdentityKeyStore.ensureInitialized(applicationContext)
        cameraExecutor = Executors.newSingleThreadExecutor()

        val root = FrameLayout(this)
        val previewView = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        statusView = TextView(this).apply {
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = android.view.Gravity.BOTTOM or android.view.Gravity.CENTER_HORIZONTAL
                bottomMargin = 64
            }
            setTextColor(android.graphics.Color.WHITE)
            textSize = 22f
            gravity = android.view.Gravity.CENTER
            setBackgroundColor(0xAA000000.toInt())
            setPadding(48, 32, 48, 32)
            text = "Point the camera at the device's pairing QR code"
        }
        root.addView(previewView)
        root.addView(statusView)
        setContentView(root)
        this.previewView = previewView

        bindTransportService()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            requestCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    private lateinit var previewView: PreviewView

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
        lifecycleScope.launch {
            viewModel.uiState.collect { state ->
                statusView.text = when (state) {
                    is PairingUiState.Idle -> "Point the camera at the device's pairing QR code"
                    is PairingUiState.Discovering -> "Looking for the device on your network…"
                    is PairingUiState.Handshaking -> "Connecting securely…\nCheck that the other device shows ${state.code}"
                    is PairingUiState.Success -> "Paired with ${state.deviceName}"
                    is PairingUiState.Failed -> "Pairing failed: ${state.reason}"
                }
                // Back to ready after a failure cleared itself: allow scanning again.
                if (state is PairingUiState.Idle) handledScan.set(false)
                if (state is PairingUiState.Success) {
                    setResult(RESULT_OK)
                    finish()
                }
            }
        }
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
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
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
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

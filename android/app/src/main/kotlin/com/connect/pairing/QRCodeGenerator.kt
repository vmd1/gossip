package com.connect.pairing

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.serialization.json.Json

/** Renders a [PairingQrPayload] as a QR code [Bitmap] — the Android counterpart to
 *  Mac's `QRCodeGenerator` (CoreImage there, ZXing's pure-Java encoder here, since
 *  Android has no built-in QR *generation* API — only ML Kit's *scanning* stack, already
 *  used by `QRScanActivity`). */
object QRCodeGenerator {
    private val json = Json { encodeDefaults = true }

    fun bitmap(payload: PairingQrPayload, sizePx: Int = 800): Bitmap {
        val text = json.encodeToString(PairingQrPayload.serializer(), payload)
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, sizePx, sizePx)
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.RGB_565)
        for (x in 0 until sizePx) {
            for (y in 0 until sizePx) {
                bitmap.setPixel(x, y, if (matrix.get(x, y)) Color.BLACK else Color.WHITE)
            }
        }
        return bitmap
    }
}

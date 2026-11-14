package com.meetingscheduler.android.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.meetingscheduler.android.Config
import com.meetingscheduler.android.models.Poll
import java.io.File

/** The link people open to join [pollId], the same one the poll detail screen shares. */
fun pollShareLink(pollId: String): String = "${Config.WEB_URL}/polls/$pollId"

/** A QR code for [text] as a matrix of dark modules, including its quiet zone. */
fun qrMatrix(text: String): BitMatrix =
    QRCodeWriter().encode(
        text, BarcodeFormat.QR_CODE, 0, 0,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0),
    )

private fun BitMatrix.toBitmap(scale: Int = 10, margin: Int = 4): Bitmap {
    val side = (width + margin * 2) * scale
    val pixels = IntArray(side * side) { Color.WHITE }
    for (y in 0 until height) for (x in 0 until width) if (get(x, y)) {
        for (dy in 0 until scale) for (dx in 0 until scale) {
            pixels[((y + margin) * scale + dy) * side + (x + margin) * scale + dx] = Color.BLACK
        }
    }
    return Bitmap.createBitmap(pixels, side, side, Bitmap.Config.ARGB_8888)
}

private fun shareText(context: Context, text: String) {
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }, null))
}

private fun shareQr(context: Context, matrix: BitMatrix, title: String) {
    val dir = File(context.cacheDir, "qr").apply { mkdirs() }
    val file = File(dir, "poll-qr.png")
    file.outputStream().use { matrix.toBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
        type = "image/png"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, "QR code for $title")
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }, null))
}

/** The last screen of the new-poll flow: the created poll's code, link and QR code. */
@Composable
fun PollSharingStep(poll: Poll, onClose: () -> Unit, onOpenPoll: () -> Unit) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val link = pollShareLink(poll.id)
    val matrix = remember(link) { qrMatrix(link) }

    Scaffold(
        topBar = {
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp)) {
                FilledTonalIconButton(onClick = onClose) { Icon(Icons.Default.Close, "Close") }
            }
        },
        bottomBar = {
            Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.End) {
                FilledIconButton(onClick = onOpenPoll, modifier = Modifier.size(60.dp)) {
                    Icon(Icons.Default.Visibility, "View poll", Modifier.size(26.dp))
                }
            }
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(64.dp).background(MaterialTheme.colorScheme.primary, androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Check, null, tint = MaterialTheme.colorScheme.onPrimary, modifier = Modifier.size(32.dp))
                }
                Spacer(Modifier.height(16.dp))
                Text("Poll created", style = MaterialTheme.typography.headlineMedium)
                Text(
                    "${poll.title} is live. Share it any way you like.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }

            ShareCard("Share code", onCopy = { clipboard.setText(AnnotatedString(poll.shareCode)) }) {
                Box(
                    Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(14.dp)).padding(vertical = 14.dp)
                        .semantics { contentDescription = "Share code ${poll.shareCode.toList().joinToString(" ")}" },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        poll.shareCode,
                        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 34.sp, letterSpacing = 8.sp,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                }
                Text("People can enter this code to join your poll.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            ShareCard("Share link", onCopy = { clipboard.setText(AnnotatedString(link)) }) {
                Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(12.dp)).padding(12.dp), contentAlignment = Alignment.Center) {
                    Text(link, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onPrimaryContainer, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                FilledTonalButton(onClick = { shareText(context, "Join my poll: ${poll.title}\n\n$link") }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Share, null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Share link")
                }
            }

            ShareCard("QR code", onCopy = null) {
                val modules = matrix.width
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    // Scanners expect dark modules on a light background in every theme.
                    Canvas(
                        Modifier.size(220.dp).background(androidx.compose.ui.graphics.Color.White, RoundedCornerShape(16.dp)).padding(14.dp)
                            .semantics { contentDescription = "QR code that opens ${poll.title}" },
                    ) {
                        val cell = size.width / modules
                        for (y in 0 until modules) for (x in 0 until modules) if (matrix.get(x, y)) {
                            drawRect(androidx.compose.ui.graphics.Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
                        }
                    }
                }
                FilledTonalButton(onClick = { shareQr(context, matrix, poll.title) }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Share, null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Share QR code")
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun ShareCard(title: String, onCopy: (() -> Unit)?, content: @Composable ColumnScope.() -> Unit) {
    Card(shape = MaterialTheme.shapes.extraLarge, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                if (onCopy != null) TextButton(onClick = onCopy) {
                    Icon(Icons.Default.ContentCopy, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Copy")
                }
            }
            content()
        }
    }
}

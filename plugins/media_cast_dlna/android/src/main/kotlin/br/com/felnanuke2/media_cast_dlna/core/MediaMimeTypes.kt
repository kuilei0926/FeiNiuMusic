package br.com.felnanuke2.media_cast_dlna.core

import java.net.URI
import java.util.Locale

internal fun mediaMimeType(uri: String, mediaType: String): String {
    val path = runCatching { URI(uri).path }.getOrNull().orEmpty()
    val extension = path.substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
    return when (extension) {
        "m3u8", "m3u" -> "application/vnd.apple.mpegurl"
        "ts" -> "video/mp2t"
        else -> when (mediaType) {
            "audio" -> when (extension) {
                "mp3", "mp2", "mpeg" -> "audio/mpeg"
                "wav", "wave" -> "audio/wav"
                "flac" -> "audio/flac"
                "aac" -> "audio/aac"
                "m4a", "mp4", "mp4a", "alac" -> "audio/mp4"
                "ogg", "oga", "opus" -> "audio/ogg"
                "wma" -> "audio/x-ms-wma"
                "aiff", "aif" -> "audio/x-aiff"
                "dsf" -> "audio/x-dsf"
                "dff" -> "audio/x-dff"
                "ape" -> "audio/x-ape"
                else -> "application/octet-stream"
            }
            "video" -> when (extension) {
                "mp4", "m4v" -> "video/mp4"
                "avi" -> "video/x-msvideo"
                "mkv" -> "video/x-matroska"
                "mov" -> "video/quicktime"
                "wmv" -> "video/x-ms-wmv"
                "flv" -> "video/x-flv"
                "webm" -> "video/webm"
                else -> "video/mp4"
            }
            "image" -> when (extension) {
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "gif" -> "image/gif"
                "bmp" -> "image/bmp"
                "webp" -> "image/webp"
                "tiff", "tif" -> "image/tiff"
                else -> "image/jpeg"
            }
            else -> "application/octet-stream"
        }
    }
}

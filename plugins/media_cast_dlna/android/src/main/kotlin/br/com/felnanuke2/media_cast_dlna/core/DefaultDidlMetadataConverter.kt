package br.com.felnanuke2.media_cast_dlna.core

import AudioMetadata
import ImageMetadata
import MediaMetadata
import VideoMetadata

class DefaultDidlMetadataConverter : DidlMetadataConverter {
    override fun toDidlLite(metadata: MediaMetadata, uri: String): String {
        // Use the comprehensive metadata utils to generate DIDL-Lite XML
        val title = when (metadata) {
            is AudioMetadata -> metadata.title ?: "Unknown Audio"
            is VideoMetadata -> metadata.title ?: "Unknown Video"
            is ImageMetadata -> metadata.title ?: "Unknown Image"
            else -> "Unknown Media"
        }

        // Detect MIME type from URI extension for better compatibility
        val mimeType = when {
            metadata is AudioMetadata -> mediaMimeType(uri, "audio")
            metadata is VideoMetadata -> mediaMimeType(uri, "video")
            metadata is ImageMetadata -> mediaMimeType(uri, "image")
            else -> mediaMimeType(uri, "audio") // Default to audio
        }

        return createDefaultMetadata(
            uri = uri,
            title = title,
            metadata = metadata,
            mimeType = mimeType
        )
    }

}

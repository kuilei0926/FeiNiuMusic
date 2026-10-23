package br.com.felnanuke2.media_cast_dlna.core

import MediaMetadata

interface DidlMetadataConverter {
    fun toDidlLite(metadata: MediaMetadata, uri: String): String
}

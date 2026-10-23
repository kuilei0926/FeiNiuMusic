package br.com.felnanuke2.media_cast_dlna.utils

/**
 * Utility functions for URL and URI operations
 */
object UrlUtils {
    
    /**
     * Builds a full URL from a base URL and a relative path
     */
    fun buildFullUrl(baseUrl: String, relativePath: String): String {
        val base = baseUrl.trimEnd('/')
        val path = relativePath.trimStart('/')
        return "$base/$path"
    }
    
    /**
     * Checks if a URI is already a full URL
     */
    fun isFullUrl(uri: String): Boolean {
        return uri.startsWith("http://") || uri.startsWith("https://")
    }
    
    /**
     * Constructs a base URL from protocol, host, and port
     */
    fun constructBaseUrl(protocol: String, host: String, port: Int): String {
        return "$protocol://$host:$port"
    }
}

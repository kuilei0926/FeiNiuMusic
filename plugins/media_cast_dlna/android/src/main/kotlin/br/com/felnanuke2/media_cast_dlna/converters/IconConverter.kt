package br.com.felnanuke2.media_cast_dlna.converters

import DeviceIcon
import Url
import org.jupnp.model.meta.Icon
import br.com.felnanuke2.media_cast_dlna.constants.DeviceConstants
import br.com.felnanuke2.media_cast_dlna.utils.UrlUtils

/**
 * Converter for UPnP Icon objects following Single Responsibility Principle
 */
class IconConverter {
    
    /**
     * Converts a UPnP Icon to DeviceIcon
     */
    fun convertIcon(icon: Icon, baseUrl: String): DeviceIcon {
        val iconUri = resolveIconUri(icon.uri.toString(), baseUrl)
        
        return DeviceIcon(
            mimeType = icon.mimeType?.toString() ?: DeviceConstants.DEFAULT_MIME_TYPE,
            width = icon.width.toLong(),
            height = icon.height.toLong(),
            uri = Url(iconUri)
        )
    }
    
    /**
     * Resolves the icon URI to a full URL
     */
    private fun resolveIconUri(iconUri: String, baseUrl: String): String {
        return if (UrlUtils.isFullUrl(iconUri)) {
            iconUri
        } else {
            UrlUtils.buildFullUrl(baseUrl, iconUri)
        }
    }
}

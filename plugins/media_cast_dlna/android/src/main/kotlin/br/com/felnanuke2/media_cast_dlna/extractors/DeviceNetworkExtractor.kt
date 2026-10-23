package br.com.felnanuke2.media_cast_dlna.extractors

import org.jupnp.model.meta.Device
import org.jupnp.model.meta.LocalDevice
import org.jupnp.model.meta.RemoteDevice
import br.com.felnanuke2.media_cast_dlna.constants.DeviceConstants
import br.com.felnanuke2.media_cast_dlna.utils.UrlUtils

/**
 * Extractor for device network information following Single Responsibility Principle
 */
class DeviceNetworkExtractor {
    
    /**
     * Extracts network information from a RemoteDevice
     */
    fun extractRemoteDeviceNetworkInfo(device: RemoteDevice): NetworkInfo {
        val identity = device.identity
        val ipAddress = identity.descriptorURL?.host ?: ""
        val port = identity.descriptorURL?.port?.toLong() ?: 0L
        
        val baseUrl = identity.descriptorURL?.let { url ->
            UrlUtils.constructBaseUrl(url.protocol, url.host, url.port)
        } ?: UrlUtils.constructBaseUrl(DeviceConstants.HTTP_PROTOCOL, ipAddress, port.toInt())
        
        return NetworkInfo(
            ipAddress = ipAddress,
            port = port,
            baseUrl = baseUrl
        )
    }
    
    /**
     * Extracts network information from a LocalDevice
     */
    fun extractLocalDeviceNetworkInfo(device: LocalDevice): NetworkInfo {
        val ipAddress = DeviceConstants.LOCALHOST_IP
        val port = DeviceConstants.DEFAULT_LOCAL_PORT
        val baseUrl = UrlUtils.constructBaseUrl(
            DeviceConstants.HTTP_PROTOCOL, 
            ipAddress, 
            if (port > 0) port.toInt() else DeviceConstants.DEFAULT_PORT.toInt()
        )
        
        return NetworkInfo(
            ipAddress = ipAddress,
            port = port,
            baseUrl = baseUrl
        )
    }
    
    /**
     * Data class to hold network information
     */
    data class NetworkInfo(
        val ipAddress: String,
        val port: Long,
        val baseUrl: String
    )
}

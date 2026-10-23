package br.com.felnanuke2.media_cast_dlna.converters

import DeviceIcon
import DeviceUdn
import DlnaDevice
import IpAddress
import NetworkPort
import Url
import org.jupnp.model.meta.Device
import org.jupnp.model.meta.LocalDevice
import org.jupnp.model.meta.RemoteDevice
import br.com.felnanuke2.media_cast_dlna.constants.DeviceConstants
import br.com.felnanuke2.media_cast_dlna.extractors.DeviceNetworkExtractor

/**
 * Main device converter that orchestrates the conversion process
 * Following Open/Closed Principle - can be extended for new device types
 */
class DlnaDeviceConverter(
    private val iconConverter: IconConverter,
    private val detailsConverter: DeviceDetailsConverter,
    private val networkExtractor: DeviceNetworkExtractor
) {
    
    /**
     * Converts a RemoteDevice to DlnaDevice
     */
    fun convertRemoteDevice(device: RemoteDevice): DlnaDevice {
        val networkInfo = networkExtractor.extractRemoteDeviceNetworkInfo(device)
        return buildDlnaDevice(device, networkInfo, DeviceConstants.DEFAULT_DEVICE_NAME)
    }
    
    /**
     * Converts a LocalDevice to DlnaDevice
     */
    fun convertLocalDevice(device: LocalDevice): DlnaDevice {
        val networkInfo = networkExtractor.extractLocalDeviceNetworkInfo(device)
        return buildDlnaDevice(device, networkInfo, DeviceConstants.DEFAULT_LOCAL_DEVICE_NAME)
    }
    
    /**
     * Builds a DlnaDevice from common device information
     */
    private fun buildDlnaDevice(
        device: Device<*, *, *>,
        networkInfo: DeviceNetworkExtractor.NetworkInfo,
        defaultName: String
    ): DlnaDevice {
        val deviceDetails = device.details
        val identity = device.identity
        
        val icons = convertIcons(device, networkInfo.baseUrl)
        
        return DlnaDevice(
            udn = DeviceUdn(identity.udn.identifierString),
            friendlyName = deviceDetails.friendlyName ?: defaultName,
            deviceType = device.type.type,
            manufacturerDetails = detailsConverter.convertManufacturerDetails(deviceDetails.manufacturerDetails),
            modelDetails = detailsConverter.convertModelDetails(deviceDetails.modelDetails),
            ipAddress = IpAddress(networkInfo.ipAddress),
            port = NetworkPort(networkInfo.port),
            presentationUrl = deviceDetails.presentationURI?.toString()?.let { Url(it) },
            icons = icons
        )
    }
    
    /**
     * Converts device icons
     */
    private fun convertIcons(device: Device<*, *, *>, baseUrl: String): List<DeviceIcon>? {
        return device.icons?.map { icon ->
            iconConverter.convertIcon(icon, baseUrl)
        }
    }
}

package br.com.felnanuke2.media_cast_dlna

import DeviceIcon
import DeviceUdn
import DlnaDevice
import IpAddress
import NetworkPort
import Url
import ManufacturerDetails
import ModelDetails
import org.jupnp.model.meta.Icon
import org.jupnp.model.meta.LocalDevice
import org.jupnp.model.meta.RemoteDevice
import br.com.felnanuke2.media_cast_dlna.converters.DlnaDeviceConverter
import br.com.felnanuke2.media_cast_dlna.converters.IconConverter
import br.com.felnanuke2.media_cast_dlna.converters.DeviceDetailsConverter
import br.com.felnanuke2.media_cast_dlna.extractors.DeviceNetworkExtractor
import br.com.felnanuke2.media_cast_dlna.factory.DeviceConverterFactory

// Global converter instance for extension functions
private val deviceConverter = DeviceConverterFactory.createDeviceConverter()
private val iconConverter = DeviceConverterFactory.createIconConverter()
private val detailsConverter = DeviceConverterFactory.createDetailsConverter()

/**
 * Extension function to convert a UPnP Icon to DeviceIcon
 */
fun Icon.toDeviceIcon(baseUrl: String): DeviceIcon {
    return iconConverter.convertIcon(this, baseUrl)
}

/**
 * Extension function to convert a RemoteDevice to DlnaDevice
 */
fun RemoteDevice.toDlnaDevice(): DlnaDevice {
    return deviceConverter.convertRemoteDevice(this)
}

/**
 * Extension function to convert a LocalDevice to DlnaDevice
 */
fun LocalDevice.toDlnaDevice(): DlnaDevice {
    return deviceConverter.convertLocalDevice(this)
}

/**
 * Extension function to convert jUPnP ManufacturerDetails to Pigeon ManufacturerDetails
 */
fun org.jupnp.model.meta.ManufacturerDetails.toManufacturerDetails(): ManufacturerDetails {
    return detailsConverter.convertManufacturerDetails(this)
}

/**
 * Extension function to convert jUPnP ModelDetails to Pigeon ModelDetails
 */
fun org.jupnp.model.meta.ModelDetails.toModelDetails(): ModelDetails {
    return detailsConverter.convertModelDetails(this)
}

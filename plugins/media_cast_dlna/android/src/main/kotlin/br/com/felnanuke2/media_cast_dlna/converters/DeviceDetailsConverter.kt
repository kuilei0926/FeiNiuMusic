package br.com.felnanuke2.media_cast_dlna.converters

import ManufacturerDetails
import ModelDetails
import Url
import br.com.felnanuke2.media_cast_dlna.constants.DeviceConstants

/**
 * Converter for device details following Single Responsibility Principle
 */
class DeviceDetailsConverter {
    
    /**
     * Converts jUPnP ManufacturerDetails to Pigeon ManufacturerDetails
     */
    fun convertManufacturerDetails(details: org.jupnp.model.meta.ManufacturerDetails?): ManufacturerDetails {
        return ManufacturerDetails(
            manufacturer = details?.manufacturer ?: DeviceConstants.DEFAULT_MANUFACTURER,
            manufacturerUri = details?.manufacturerURI?.toString()?.let { Url(it) }
        )
    }
    
    /**
     * Converts jUPnP ModelDetails to Pigeon ModelDetails
     */
    fun convertModelDetails(details: org.jupnp.model.meta.ModelDetails?): ModelDetails {
        return ModelDetails(
            modelName = details?.modelName ?: DeviceConstants.DEFAULT_MODEL_NAME,
            modelDescription = details?.modelDescription,
            modelNumber = details?.modelNumber,
            modelUri = details?.modelURI?.toString()?.let { Url(it) }
        )
    }
}

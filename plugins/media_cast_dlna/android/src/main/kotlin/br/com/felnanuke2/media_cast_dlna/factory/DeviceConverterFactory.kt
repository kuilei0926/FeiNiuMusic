package br.com.felnanuke2.media_cast_dlna.factory

import br.com.felnanuke2.media_cast_dlna.converters.DlnaDeviceConverter
import br.com.felnanuke2.media_cast_dlna.converters.IconConverter
import br.com.felnanuke2.media_cast_dlna.converters.DeviceDetailsConverter
import br.com.felnanuke2.media_cast_dlna.extractors.DeviceNetworkExtractor

/**
 * Factory for creating device converters following Dependency Inversion Principle
 */
object DeviceConverterFactory {
    
    /**
     * Creates a configured DlnaDeviceConverter instance
     */
    fun createDeviceConverter(): DlnaDeviceConverter {
        return DlnaDeviceConverter(
            iconConverter = IconConverter(),
            detailsConverter = DeviceDetailsConverter(),
            networkExtractor = DeviceNetworkExtractor()
        )
    }
    
    /**
     * Creates an IconConverter instance
     */
    fun createIconConverter(): IconConverter {
        return IconConverter()
    }
    
    /**
     * Creates a DeviceDetailsConverter instance
     */
    fun createDetailsConverter(): DeviceDetailsConverter {
        return DeviceDetailsConverter()
    }
    
    /**
     * Creates a DeviceNetworkExtractor instance
     */
    fun createNetworkExtractor(): DeviceNetworkExtractor {
        return DeviceNetworkExtractor()
    }
}

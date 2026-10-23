package br.com.felnanuke2.media_cast_dlna.core

import org.jupnp.model.meta.Device
import org.jupnp.model.meta.Service
import org.jupnp.model.types.UDAServiceId

interface DeviceServiceManager {
    fun findService(device: Device<*, *, *>, serviceId: String): Service<*, *>?
}

class DefaultDeviceServiceManager : DeviceServiceManager {
    override fun findService(device: Device<*, *, *>, serviceId: String): Service<*, *>? {
        return device.findService(UDAServiceId(serviceId))
    }
}

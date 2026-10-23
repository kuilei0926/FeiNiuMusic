package br.com.felnanuke2.media_cast_dlna

import DlnaDevice
import DiscoveryEventsFlutterApi
import DeviceUdn
import android.util.Log
import android.os.Handler
import android.os.Looper
import org.jupnp.model.meta.LocalDevice
import org.jupnp.model.meta.RemoteDevice
import org.jupnp.registry.Registry
import org.jupnp.registry.RegistryListener
import java.lang.Exception

/**
 * RegistryListener implementation for handling UPnP device discovery events.
 * This class manages device discovery callbacks and communicates with Flutter
 * through the provided MediaCastDlnaApi and DeviceDiscoveryApi instances.
 *
 * IMPORTANT: All Flutter API calls must be executed on the main UI thread.
 * The UPnP registry callbacks are executed on background threads (e.g., jupnp-4),
 * so this class uses a Handler to post all Flutter API calls to the main thread
 * to avoid the "Methods marked with @UiThread must be executed on the main thread" error.
 */
class UpnpRegistryListener(
    private val discoveryEventsFlutterApi: DiscoveryEventsFlutterApi? = null,
) : RegistryListener {

    private enum class DiscoveryTargetFilter {
        ALL_MEDIA,
        MEDIA_RENDERER,
        MEDIA_SERVER
    }

    private val _devices = mutableListOf<DlnaDevice>()
    val devices: List<DlnaDevice> get() = _devices
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var activeFilter: DiscoveryTargetFilter = DiscoveryTargetFilter.ALL_MEDIA

    companion object {
        // Device types that we're interested in for media casting
        private val MEDIA_DEVICE_TYPES = setOf(
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:schemas-upnp-org:device:MediaRenderer:2",
            "urn:schemas-upnp-org:device:MediaRenderer:3",
            "urn:schemas-upnp-org:device:MediaServer:1",
            "urn:schemas-upnp-org:device:MediaServer:2",
            "urn:schemas-upnp-org:device:MediaServer:3",
            "urn:schemas-upnp-org:device:MediaServer:4"
        )

        // Device type prefixes to filter for media devices
        private val MEDIA_DEVICE_PREFIXES = setOf(
            "MediaRenderer", "MediaServer"
        )

        // Devices to exclude (like Internet Gateway Devices)
        private val EXCLUDED_DEVICE_PREFIXES = setOf(
            "InternetGatewayDevice", "WANDevice", "LANDevice", "WFADevice"
        )
    }

    fun setSearchTarget(searchTarget: String?) {
        activeFilter = when {
            searchTarget.isNullOrBlank() -> DiscoveryTargetFilter.ALL_MEDIA
            searchTarget.contains("MediaRenderer", ignoreCase = true) -> DiscoveryTargetFilter.MEDIA_RENDERER
            searchTarget.contains("MediaServer", ignoreCase = true) -> DiscoveryTargetFilter.MEDIA_SERVER
            else -> DiscoveryTargetFilter.ALL_MEDIA
        }
    }

    fun clearDiscoveredDevices() {
        val removedDevices = _devices.toList()
        _devices.clear()

        removedDevices.forEach { device ->
            notifyDeviceLost(device.udn)
        }
    }

    private fun notifyDeviceFound(device: DlnaDevice) {
        mainHandler.post {
            discoveryEventsFlutterApi?.onDeviceFound(device) { result ->
                result.exceptionOrNull()?.let { error ->
                    Log.w("UpnpRegistryListener", "Failed to send onDeviceFound callback", error)
                }
            }
        }
    }

    private fun notifyDeviceLost(deviceUdn: DeviceUdn) {
        mainHandler.post {
            discoveryEventsFlutterApi?.onDeviceLost(deviceUdn) { result ->
                result.exceptionOrNull()?.let { error ->
                    Log.w("UpnpRegistryListener", "Failed to send onDeviceLost callback", error)
                }
            }
        }
    }

    private fun notifyRendererOffline(deviceUdn: DeviceUdn) {
        mainHandler.post {
            discoveryEventsFlutterApi?.onRendererOffline(deviceUdn) { result ->
                result.exceptionOrNull()?.let { error ->
                    Log.w("UpnpRegistryListener", "Failed to send onRendererOffline callback", error)
                }
            }
        }
    }

    private fun matchesActiveSearchTarget(deviceType: String): Boolean {
        return when (activeFilter) {
            DiscoveryTargetFilter.ALL_MEDIA -> {
                MEDIA_DEVICE_PREFIXES.any { deviceType.contains(it, ignoreCase = true) }
            }

            DiscoveryTargetFilter.MEDIA_RENDERER -> {
                deviceType.contains("MediaRenderer", ignoreCase = true)
            }

            DiscoveryTargetFilter.MEDIA_SERVER -> {
                deviceType.contains("MediaServer", ignoreCase = true)
            }
        }
    }

    private fun isRendererType(deviceType: String): Boolean {
        return deviceType.contains("MediaRenderer", ignoreCase = true)
    }

    private fun isRendererDevice(device: RemoteDevice): Boolean {
        return isMediaDevice(device) && isRendererType(device.type.toString())
    }

    private fun isRendererDevice(device: LocalDevice): Boolean {
        return isMediaDevice(device) && isRendererType(device.type.toString())
    }

    /**
     * Check if a device is a media device (MediaRenderer or MediaServer)
     */
    private fun isMediaDevice(device: RemoteDevice): Boolean {
        val deviceType = device.type.toString()

        // First check if it's explicitly excluded
        if (EXCLUDED_DEVICE_PREFIXES.any { deviceType.contains(it, ignoreCase = true) }) {
            return false
        }

        // Check for exact match with known media device types
        if (MEDIA_DEVICE_TYPES.contains(deviceType)) {
            return matchesActiveSearchTarget(deviceType)
        }

        // Check for partial match with media device prefixes
        val isMediaDevice = MEDIA_DEVICE_PREFIXES.any { deviceType.contains(it, ignoreCase = true) }
        return isMediaDevice && matchesActiveSearchTarget(deviceType)
    }

    /**
     * Check if a local device is a media device (MediaRenderer or MediaServer)
     */
    private fun isMediaDevice(device: LocalDevice): Boolean {
        val deviceType = device.type.toString()

        // First check if it's explicitly excluded
        if (EXCLUDED_DEVICE_PREFIXES.any { deviceType.contains(it, ignoreCase = true) }) {
            return false
        }

        // Check for exact match with known media device types
        if (MEDIA_DEVICE_TYPES.contains(deviceType)) {
            return matchesActiveSearchTarget(deviceType)
        }

        // Check for partial match with media device prefixes
        val isMediaDevice = MEDIA_DEVICE_PREFIXES.any { deviceType.contains(it, ignoreCase = true) }
        return isMediaDevice && matchesActiveSearchTarget(deviceType)
    }

    override fun remoteDeviceDiscoveryStarted(registry: Registry?, device: RemoteDevice?) {
        // This method is called when remote device discovery starts.

        device?.let {
            // Only notify Flutter if this is a media device
            if (isMediaDevice(it)) {
              
                // Note: We don't add the device here yet, only when discovery is complete
            }
        }
    }

    override fun remoteDeviceDiscoveryFailed(
        registry: Registry?, device: RemoteDevice?, e: Exception?
    ) {
        device?.let {
            if (isMediaDevice(it)) {
                Log.w(
                    "UpnpRegistryListener",
                    "Remote device discovery failed for: ${it.details?.friendlyName}",
                    e
                )

                // Remove the device from our list if it failed discovery
                val dlnaDevice = it.toDlnaDevice()
                val iterator = _devices.iterator()
                while (iterator.hasNext()) {
                    if (iterator.next().udn == dlnaDevice?.udn) {
                        iterator.remove()
                        dlnaDevice?.udn?.let { udn ->
                            notifyDeviceLost(udn)
                            if (isRendererDevice(it)) {
                                notifyRendererOffline(udn)
                            }
                        }
                        break
                    }
                }
            }
        }
    }

    override fun remoteDeviceAdded(registry: Registry?, device: RemoteDevice?) {
        device?.let {
            // Only process media devices
            if (isMediaDevice(it)) {
               

                // Convert to DlnaDevice and add to devices list
                val dlnaDevice = it.toDlnaDevice()
                dlnaDevice?.let { dlna ->
                    // Check if device already exists to avoid duplicates
                    val existingIndex = _devices.indexOfFirst { d -> d.udn == dlna.udn }
                    if (existingIndex == -1) {
                        _devices.add(dlna)
                        notifyDeviceFound(dlna)
                    } else {
                       
                    }
                }
            }
        }
    }

    override fun remoteDeviceUpdated(registry: Registry?, device: RemoteDevice?) {
        device?.let {
            // Only process media devices
            if (isMediaDevice(it)) {
                // Convert to DlnaDevice and update in the list
                val dlnaDevice = it.toDlnaDevice()
                dlnaDevice.let { dlna ->
                    val index = _devices.indexOfFirst { d -> d.udn == dlna.udn }
                    if (index != -1) {
                        _devices[index] = dlna
                       
                    } else {
                        _devices.add(dlna)
                        notifyDeviceFound(dlna)
                    }
                }
            }
        }
    }

    override fun remoteDeviceRemoved(registry: Registry?, device: RemoteDevice?) {
        //remove device with same udn
        val deviceUdn = device?.identity?.udn ?: return
       
        // Remove the device from our list
        val iterator = _devices.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().udn.value == deviceUdn.identifierString) {
                iterator.remove()
                val removedDeviceUdn = DeviceUdn(deviceUdn.identifierString)
                notifyDeviceLost(removedDeviceUdn)
                if (device != null && isRendererDevice(device)) {
                    notifyRendererOffline(removedDeviceUdn)
                }
                break
            }
        }
    }

    override fun localDeviceAdded(registry: Registry?, device: LocalDevice?) {
        device?.let {
            // Only process media devices
            if (isMediaDevice(it)) {
              

                // Convert to DlnaDevice and add to devices list
                val dlnaDevice = it.toDlnaDevice()
                dlnaDevice?.let { dlna ->
                    // Check if device already exists to avoid duplicates
                    val existingIndex = _devices.indexOfFirst { d -> d.udn == dlna.udn }
                    if (existingIndex == -1) {
                        _devices.add(dlna)
                        notifyDeviceFound(dlna)
                    } else {
                      
                    }
                }
            }
        }
    }

    override fun localDeviceRemoved(registry: Registry?, device: LocalDevice?) {
        device?.let {
            // Only process media devices
            if (isMediaDevice(it)) {
              

                // Remove the device from our list
                val dlnaDevice = it.toDlnaDevice()
                dlnaDevice?.let { dlna ->
                    val iterator = _devices.iterator()
                    while (iterator.hasNext()) {
                        if (iterator.next().udn == dlna.udn) {
                            iterator.remove()
                            notifyDeviceLost(dlna.udn)
                            if (isRendererDevice(it)) {
                                notifyRendererOffline(dlna.udn)
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    override fun beforeShutdown(registry: Registry?) {
        // This method is called before the registry is shut down.
        // Clear all devices from the list

        _devices.clear()
    }

    override fun afterShutdown() {
        // This method is called after the registry has been shut down.
        // Ensure devices list is cleared

        _devices.clear()
    }
}

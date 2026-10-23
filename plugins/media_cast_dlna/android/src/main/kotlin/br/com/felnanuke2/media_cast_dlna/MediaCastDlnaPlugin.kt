package br.com.felnanuke2.media_cast_dlna

import DeviceUdn
import DiscoveryEventsFlutterApi
import DiscoveryOptions
import DlnaDevice
import DlnaService
import MediaCastDlnaApi
import MediaMetadata
import PlaybackInfo
import SubtitleTrack
import TransportState
import VolumeInfo
import VolumeLevel
import MuteOperation
import MuteState
import PlaybackSpeed
import PlaybackSpeedToken
import SupportedPlaybackSpeeds
import TimePosition
import TimeDuration
import Url
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.ComponentName
import android.os.IBinder
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import org.jupnp.android.AndroidUpnpService
import org.jupnp.android.AndroidUpnpServiceImpl
import br.com.felnanuke2.media_cast_dlna.core.DidlMetadataConverter
import br.com.felnanuke2.media_cast_dlna.core.DefaultDidlMetadataConverter
import br.com.felnanuke2.media_cast_dlna.core.MediaControlManager
import br.com.felnanuke2.media_cast_dlna.core.DeviceDiscoveryManager
import br.com.felnanuke2.media_cast_dlna.core.VolumeManager
import br.com.felnanuke2.media_cast_dlna.core.WifiMulticastLockManager

/** MediaCastDlnaPlugin - Refactored to act as a simple Facade with coroutines support */
class MediaCastDlnaPlugin : FlutterPlugin, MediaCastDlnaApi {
    private var context: Context? = null
    private var upnpService: AndroidUpnpService? = null
    private var isServiceBound = false
    private lateinit var upnpRegistryListener: UpnpRegistryListener
    private var discoveryEventsFlutterApi: DiscoveryEventsFlutterApi? = null
    private var wifiMulticastLockManager: WifiMulticastLockManager? = null

    // Coroutine scope for managing async operations
    private val pluginScope =
        CoroutineScope(SupervisorJob() + Dispatchers.IO) // Changed to IO dispatcher
    private var discoveryTimeoutJob: Job? = null

    // Service connection for UPnP service
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, service: IBinder) {
            upnpService = service as AndroidUpnpService
            upnpService?.get()?.startup()
            upnpService?.registry?.addListener(upnpRegistryListener)
            isServiceBound = true
        }

        override fun onServiceDisconnected(className: ComponentName) {
            upnpService = null
            isServiceBound = false
        }
    }

    private val didlMetadataConverter: DidlMetadataConverter = DefaultDidlMetadataConverter()
    private val mediaControlManager: MediaControlManager by lazy {
        MediaControlManager(upnpService)
    }
    private val deviceDiscoveryManager: DeviceDiscoveryManager by lazy {
        DeviceDiscoveryManager(upnpService, upnpRegistryListener)
    }
    private val volumeManager: VolumeManager by lazy {
        VolumeManager(upnpService)
    }

    // --- Plugin lifecycle ---
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        wifiMulticastLockManager = context?.let { WifiMulticastLockManager(it) }
        discoveryEventsFlutterApi = DiscoveryEventsFlutterApi(flutterPluginBinding.binaryMessenger)
        upnpRegistryListener = UpnpRegistryListener(discoveryEventsFlutterApi)
        MediaCastDlnaApi.setUp(flutterPluginBinding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MediaCastDlnaApi.setUp(binding.binaryMessenger, null)
        discoveryTimeoutJob?.cancel()
        discoveryTimeoutJob = null
        if (upnpService != null && context != null) {
            context?.unbindService(serviceConnection)
        }
        wifiMulticastLockManager?.cleanup()
        discoveryEventsFlutterApi = null
        upnpService = null
        context = null
    }

    override fun initializeUpnpService(callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                context?.let {
                    val intent = Intent(it, AndroidUpnpServiceImpl::class.java)
                    val bindResult =
                        it.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
                    callback(Result.success(Unit))
                } ?: run {
                    val error =
                        IllegalStateException("Context is not available. Ensure the plugin is attached to the engine.")
                    callback(Result.failure(dlnaPlatformError(error)))
                }
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun isUpnpServiceInitialized(callback: (Result<Boolean>) -> Unit) {
        pluginScope.launch {
            try {
                val isInitialized = upnpService != null && isServiceBound
                callback(Result.success(isInitialized))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun shutdownUpnpService(callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                discoveryTimeoutJob?.cancel()
                discoveryTimeoutJob = null
                if (upnpService != null && context != null && isServiceBound) {
                    try {
                        context!!.unbindService(serviceConnection)
                    } catch (e: IllegalArgumentException) {
                        // Service unbind failed, ignore
                    }
                    isServiceBound = false
                }
                upnpService = null
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    // --- Discovery ---
    override fun startDiscovery(options: DiscoveryOptions, callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                if (!isServiceBound) {
                    throw IllegalStateException("UPnP service is not bound. Please ensure the service is started before calling startDiscovery.")
                }

                if (options.timeout.seconds <= 0) {
                    throw IllegalArgumentException("Discovery timeout must be greater than 0 seconds.")
                }

                upnpRegistryListener.setSearchTarget(options.searchTarget?.target)
                upnpRegistryListener.clearDiscoveredDevices()

                // Acquire WiFi multicast lock to ensure device discovery works on all Android ROMs
                wifiMulticastLockManager?.acquireMulticastLock()

                discoveryTimeoutJob?.cancel()
                deviceDiscoveryManager.startDiscovery()

                discoveryTimeoutJob = pluginScope.launch {
                    delay(options.timeout.seconds * 1000)
                    try {
                        deviceDiscoveryManager.stopDiscovery()
                    } finally {
                        wifiMulticastLockManager?.releaseMulticastLock()
                    }
                }

                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun stopDiscovery(callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                discoveryTimeoutJob?.cancel()
                discoveryTimeoutJob = null
                deviceDiscoveryManager.stopDiscovery()
                // Release WiFi multicast lock when discovery is stopped
                wifiMulticastLockManager?.releaseMulticastLock()
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getDiscoveredDevices(callback: (Result<List<DlnaDevice>>) -> Unit) {
        pluginScope.launch {
            try {
                val devices = deviceDiscoveryManager.getDiscoveredDevices()
                callback(Result.success(devices))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun refreshDevice(deviceUdn: DeviceUdn, callback: (Result<DlnaDevice?>) -> Unit) {
        pluginScope.launch {
            try {
                val device = deviceDiscoveryManager.refreshDevice(deviceUdn.value)
                callback(Result.success(device))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getDeviceServices(
        deviceUdn: DeviceUdn, callback: (Result<List<DlnaService>>) -> Unit
    ) {
        pluginScope.launch {
            try {
                val services = deviceDiscoveryManager.getDeviceServices(deviceUdn.value)
                callback(Result.success(services))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun hasService(
        deviceUdn: DeviceUdn, serviceType: String, callback: (Result<Boolean>) -> Unit
    ) {
        pluginScope.launch {
            try {
                val hasService = deviceDiscoveryManager.hasService(deviceUdn.value, serviceType)
                callback(Result.success(hasService))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun isDeviceOnline(deviceUdn: DeviceUdn, callback: (Result<Boolean>) -> Unit) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.success(false))
            return
        }

        pluginScope.launch {
            try {
                val isOnline = withTimeout(5000L) { // 5 second timeout for connectivity check
                    deviceDiscoveryManager.isDeviceOnline(deviceUdn.value)
                }
                callback(Result.success(isOnline))
            } catch (e: TimeoutCancellationException) {
                callback(Result.success(false))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getDeviceManually(uri: Url, callback: (Result<DlnaDevice?>) -> Unit) {
        // This method is designed for iOS (mDNS-restricted environments).
        // On Android, multicast discovery works normally; throw to inform the caller.
        callback(Result.failure(UnsupportedOperationException("getDeviceManually is not supported on Android. Use startDiscovery() instead.")))
    }

    // --- Media Control (delegating to managers with coroutines) ---
    override fun setMediaUri(
        deviceUdn: DeviceUdn, uri: Url, metadata: MediaMetadata, callback: (Result<Unit>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                val finalMetadata = didlMetadataConverter.toDidlLite(metadata, uri.value)

                withTimeout(30000L) {
                    mediaControlManager.setMediaUri(deviceUdn.value, uri.value, finalMetadata)
                }
                callback(Result.success(Unit))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(dlnaPlatformError(e)))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun setMediaUriWithSubtitles(
        deviceUdn: DeviceUdn,
        uri: Url,
        metadata: MediaMetadata,
        subtitleTracks: List<SubtitleTrack>,
        callback: (Result<Unit>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                val mediaControlManager = MediaControlManager(upnpService)
                val metadataConverter = DefaultDidlMetadataConverter()
                val finalMetadata = metadataConverter.toDidlLite(metadata, uri.value)

                withTimeout(30000) { // 30-second timeout
                    mediaControlManager.setMediaUriWithSubtitlesEnhanced(
                        deviceUdn.value, uri.value, finalMetadata, subtitleTracks
                    )
                }

                callback(Result.success(Unit))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(Exception("Operation timed out: ${e.message}")))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun supportsSubtitleControl(
        deviceUdn: DeviceUdn, callback: (Result<Boolean>) -> Unit
    ) {
        pluginScope.launch {
            try {
                val supportsSubtitles =
                    mediaControlManager.checkDeviceSubtitleSupport(deviceUdn.value)
                callback(Result.success(supportsSubtitles))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun setSubtitleTrack(
        deviceUdn: DeviceUdn, subtitleTrackId: String?, callback: (Result<Unit>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                val mediaControlManager = MediaControlManager(upnpService)

                withTimeout(10000) { // 10-second timeout
                    mediaControlManager.setSubtitleTrack(deviceUdn.value, subtitleTrackId)
                }

                callback(Result.success(Unit))
            } catch (e: UnsupportedOperationException) {
                callback(Result.failure(dlnaPlatformError(e)))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(Exception("Operation timed out: ${e.message}")))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getAvailableSubtitleTracks(
        deviceUdn: DeviceUdn, callback: (Result<List<SubtitleTrack>>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.success(emptyList()))
            return
        }

        pluginScope.launch {
            try {
                val tracks = withTimeout(10000) {
                    mediaControlManager.getAvailableSubtitleTracks(deviceUdn.value)
                }
                callback(Result.success(tracks))
            } catch (e: TimeoutCancellationException) {
                callback(Result.success(emptyList()))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getCurrentSubtitleTrack(
        deviceUdn: DeviceUdn, callback: (Result<SubtitleTrack?>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.success(null))
            return
        }

        pluginScope.launch {
            try {
                val track = withTimeout(10000) {
                    mediaControlManager.getCurrentSubtitleTrack(deviceUdn.value)
                }
                callback(Result.success(track))
            } catch (e: TimeoutCancellationException) {
                callback(Result.success(null))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun play(deviceUdn: DeviceUdn, callback: (Result<Unit>) -> Unit) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                withTimeout(30000L) { // 30 second timeout
                    mediaControlManager.play(deviceUdn.value)
                }
                callback(Result.success(Unit))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(dlnaPlatformError(e)))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun pause(deviceUdn: DeviceUdn, callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                mediaControlManager.pause(deviceUdn.value)
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun stop(deviceUdn: DeviceUdn, callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                mediaControlManager.stop(deviceUdn.value)
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun seek(
        deviceUdn: DeviceUdn, position: TimePosition, callback: (Result<Unit>) -> Unit
    ) {
        pluginScope.launch {
            try {
                mediaControlManager.seek(deviceUdn.value, position.seconds.toLong())
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun setVolume(deviceUdn: DeviceUdn, volumeLevel: VolumeLevel, callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                volumeManager.setVolume(deviceUdn.value, volumeLevel.percentage)
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getVolumeInfo(deviceUdn: DeviceUdn, callback: (Result<VolumeInfo>) -> Unit) {
        pluginScope.launch {
            try {
                val volumeInfo = volumeManager.getVolumeInfo(deviceUdn)
                callback(Result.success(volumeInfo))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun setMute(deviceUdn: DeviceUdn, muteOperation: MuteOperation, callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                volumeManager.setMute(deviceUdn.value, muteOperation.shouldMute)
                callback(Result.success(Unit))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getPlaybackInfo(deviceUdn: DeviceUdn, callback: (Result<PlaybackInfo>) -> Unit) {
        pluginScope.launch {
            try {
                val playbackInfo = mediaControlManager.getPlaybackInfo(deviceUdn.value)
                callback(Result.success(playbackInfo))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getCurrentPosition(deviceUdn: DeviceUdn, callback: (Result<TimePosition>) -> Unit) {
        pluginScope.launch {
            try {
                val position = mediaControlManager.getCurrentPosition(deviceUdn.value)
                callback(Result.success(TimePosition(position)))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getTransportState(
        deviceUdn: DeviceUdn, callback: (Result<TransportState>) -> Unit
    ) {
        pluginScope.launch {
            try {
                val transportState = mediaControlManager.getTransportState(deviceUdn.value)
                callback(Result.success(transportState))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun getSupportedPlaybackSpeeds(
        deviceUdn: DeviceUdn,
        callback: (Result<SupportedPlaybackSpeeds>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                val supportedSpeeds = withTimeout(5000L) {
                    mediaControlManager.getSupportedPlaybackSpeeds(deviceUdn.value)
                }
                val tokens = supportedSpeeds.map { PlaybackSpeedToken(it) }
                callback(Result.success(SupportedPlaybackSpeeds(tokens)))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(Exception("Operation timed out: ${e.message}")))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }

    override fun setPlaybackSpeed(
        deviceUdn: DeviceUdn,
        speed: PlaybackSpeed,
        callback: (Result<Unit>) -> Unit
    ) {
        if (!isServiceBound || upnpService == null) {
            callback(Result.failure(Exception("UPnP service not initialized")))
            return
        }

        pluginScope.launch {
            try {
                withTimeout(10000L) { // 10 second timeout
                    mediaControlManager.setPlaybackSpeed(deviceUdn.value, speed.value)
                }
                callback(Result.success(Unit))
            } catch (e: UnsupportedOperationException) {
                callback(Result.failure(dlnaPlatformError(e)))
            } catch (e: TimeoutCancellationException) {
                callback(Result.failure(Exception("Operation timed out: ${e.message}")))
            } catch (e: Exception) {
                callback(Result.failure(dlnaPlatformError(e)))
            }
        }
    }
}


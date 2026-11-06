package br.com.felnanuke2.media_cast_dlna.core

import PlaybackInfo
import TransportState
import SubtitleTrack
import TimePosition
import TimeDuration
import Url
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.jupnp.android.AndroidUpnpService
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.message.UpnpResponse
import org.jupnp.model.meta.Device
import org.jupnp.model.types.UDAServiceId
import org.jupnp.support.avtransport.callback.SetAVTransportURI
import org.jupnp.support.avtransport.callback.Play
import org.jupnp.support.avtransport.callback.GetTransportInfo
import org.jupnp.support.avtransport.callback.GetPositionInfo
import org.jupnp.support.model.TransportInfo
import org.jupnp.controlpoint.ActionCallback
import org.jupnp.model.types.UnsignedIntegerFourBytes
import org.jupnp.support.contentdirectory.DIDLParser
import org.jupnp.support.model.ProtocolInfo
import org.jupnp.support.model.Res
import org.jupnp.model.meta.Service

class MediaControlManager(upnpService: AndroidUpnpService?) : BaseManager(upnpService) {
    
    /**
     * Sets media URI using coroutines for cleaner async handling
     */
    suspend fun setMediaUri(deviceUdn: String, uri: String, finalMetadata: String) {
        
        
        
        
        try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            
            val controlPoint = requireUpnpService().controlPoint
            
            
            val setUriCallback = object : SetAVTransportURI(avTransportService, uri, finalMetadata) {
                override fun success(invocation: ActionInvocation<*>?) {
                    
                    invocation?.let { inv ->
                        
                        inv.output?.forEach { output ->
                            
                        }
                    }
                }
                override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                    
                    operation?.let { resp ->
                        
                        
                    }
                    invocation?.let { inv ->
                        
                        inv.input?.forEach { input ->
                            
                        }
                    }
                }
            }
            
            
            controlPoint.executeSuspending(setUriCallback)
            
            
            // Add a small delay to ensure the device processes the URI before play is called
            kotlinx.coroutines.delay(500)
        } catch (e: Exception) {
            
            throw e
        }
    }

    /**
     * Plays media using coroutines
     */
    suspend fun play(deviceUdn: String) {
        
        
        try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            
            val controlPoint = requireUpnpService().controlPoint
            
            
            val playCallback = object : Play(avTransportService) {
                override fun success(invocation: ActionInvocation<*>?) {
                    
                    invocation?.let { inv ->
                        
                        inv.output?.forEach { output ->
                            
                        }
                    }
                }
                override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                    
                    operation?.let { resp ->
                        
                        
                    }
                    invocation?.let { inv ->
                        
                        inv.input?.forEach { input ->
                            
                        }
                    }
                }
            }
            
            
            controlPoint.executeSuspending(playCallback)
            
        } catch (e: Exception) {
            
            throw e
        }
    }

    /**
     * Pauses media using coroutines with proper state checking
     */
    suspend fun pause(deviceUdn: String) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        // First check if device is playing
        val transportInfo = controlPoint.getTransportInfoSuspending(avTransportService)
        if (transportInfo?.currentTransportState != org.jupnp.support.model.TransportState.PLAYING) {

            return
        }
        
        val pauseAction = avTransportService.getAction("Pause")
            ?: throw IllegalStateException("Pause action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(pauseAction).apply {
            setInput("InstanceID", "0")
        }
        
        val pauseCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(pauseCallback)
    }

    /**
     * Stops media using coroutines with proper state checking
     */
    suspend fun stop(deviceUdn: String) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        // First check if device is already stopped
        val transportInfo = controlPoint.getTransportInfoSuspending(avTransportService)
        if (transportInfo?.currentTransportState == org.jupnp.support.model.TransportState.STOPPED) {
            
            return
        }
        
        val stopAction = avTransportService.getAction("Stop")
            ?: throw IllegalStateException("Stop action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(stopAction).apply {
            setInput("InstanceID", "0")
        }
        
        val stopCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(stopCallback)
    }

    /**
     * Seeks to a specific position using coroutines
     */
    suspend fun seek(deviceUdn: String, positionSeconds: Long) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        val seekAction = avTransportService.getAction("Seek")
            ?: throw IllegalStateException("Seek action not available on device $deviceUdn")
        
        val timeString = formatSecondsToTime(positionSeconds)
        
        val actionInvocation = ActionInvocation(seekAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
            setInput("Unit", "REL_TIME")
            setInput("Target", timeString)
        }
        
        val seekCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(seekCallback)
    }

    /**
     * Goes to next track using coroutines
     */
    suspend fun next(deviceUdn: String) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        val nextAction = avTransportService.getAction("Next")
            ?: throw IllegalStateException("Next action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(nextAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
        }
        
        val nextCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(nextCallback)
    }

    /**
     * Goes to previous track using coroutines
     */
    suspend fun previous(deviceUdn: String) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        val previousAction = avTransportService.getAction("Previous")
            ?: throw IllegalStateException("Previous action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(previousAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
        }
        
        val previousCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(previousCallback)
    }
    
    /**
     * Gets current playback position using coroutines
     */
    suspend fun getCurrentPosition(deviceUdn: String): Long {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        return try {
            val positionInfo = controlPoint.getPositionInfoSuspending(avTransportService)
            parseTimeToSeconds(positionInfo?.relTime).toLong()
        } catch (e: Exception) {
            throw e
        }
    }
    
    /**
     * Gets transport state using coroutines
     */
    suspend fun getTransportState(deviceUdn: String): TransportState {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        return try {
            val transportInfo = controlPoint.getTransportInfoSuspending(avTransportService)
            when (transportInfo?.currentTransportState) {
                org.jupnp.support.model.TransportState.PLAYING -> TransportState.PLAYING
                org.jupnp.support.model.TransportState.PAUSED_PLAYBACK -> TransportState.PAUSED
                org.jupnp.support.model.TransportState.STOPPED -> TransportState.STOPPED
                org.jupnp.support.model.TransportState.TRANSITIONING -> TransportState.TRANSITIONING
                org.jupnp.support.model.TransportState.NO_MEDIA_PRESENT -> TransportState.NO_MEDIA_PRESENT
                else -> TransportState.STOPPED
            }
        } catch (e: Exception) {
            throw e
        }
    }
    
    /**
     * Gets complete playback info using coroutines (runs position and transport info queries concurrently)
     */
    suspend fun getPlaybackInfo(deviceUdn: String): PlaybackInfo = coroutineScope {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        try {
            // Execute both queries concurrently for better performance
            val transportInfoDeferred = async { 
                controlPoint.getTransportInfoSuspending(avTransportService) 
            }
            val positionInfoDeferred = async { 
                controlPoint.getPositionInfoSuspending(avTransportService) 
            }
            
            val transportInfo = transportInfoDeferred.await()
            val positionInfo = positionInfoDeferred.await()
            
            val state = when (transportInfo?.currentTransportState) {
                org.jupnp.support.model.TransportState.PLAYING -> TransportState.PLAYING
                org.jupnp.support.model.TransportState.PAUSED_PLAYBACK -> TransportState.PAUSED
                org.jupnp.support.model.TransportState.STOPPED -> TransportState.STOPPED
                org.jupnp.support.model.TransportState.TRANSITIONING -> TransportState.TRANSITIONING
                org.jupnp.support.model.TransportState.NO_MEDIA_PRESENT -> TransportState.NO_MEDIA_PRESENT
                else -> TransportState.STOPPED
            }
            
            PlaybackInfo(
                state = state,
                position = TimePosition(parseTimeToSeconds(positionInfo?.relTime).toLong()),
                duration = TimeDuration(parseTimeToSeconds(positionInfo?.trackDuration).toLong()),
                currentTrackUri = positionInfo?.trackURI,
                currentTrackMetadata = parseMediaMetadataFromDidl(positionInfo?.trackMetaData)
            )
        } catch (e: Exception) {
            throw e
        }
    }
    
    /**
     * High-level method to cast video (combines setMediaUri + play) using coroutines
     */
    suspend fun castVideo(deviceUdn: String, videoUrl: String, metadata: String) {
        try {
            
            setMediaUri(deviceUdn, videoUrl, metadata)
            
            
            play(deviceUdn)
            
            
        } catch (e: Exception) {
            
            throw RuntimeException("Failed to cast video: ${e.message}", e)
        }
    }
    
    /**
     * Set media URI with subtitle tracks
     */
    suspend fun setMediaUriWithSubtitles(
        deviceUdn: String, 
        uri: String, 
        finalMetadata: String,
        subtitleTracks: List<SubtitleTrack>
    ) {
        
        
        
        
        try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            
            val controlPoint = requireUpnpService().controlPoint
            
            
            // Enhanced metadata with subtitle information
            val enhancedMetadata = enhanceMetadataWithSubtitles(finalMetadata, subtitleTracks)
            
            val setUriCallback = object : SetAVTransportURI(avTransportService, uri, enhancedMetadata) {
                override fun success(invocation: ActionInvocation<*>?) {
                    
                }

                override fun failure(
                    invocation: ActionInvocation<*>?,
                    operation: UpnpResponse?,
                    defaultMsg: String?
                ) {
                    val errorMsg = "SetAVTransportURI failed: ${operation?.responseDetails} - $defaultMsg"
                    
                    throw RuntimeException(errorMsg)
                }
            }
            
            controlPoint.execute(setUriCallback)
            withContext(Dispatchers.IO) {
                delay(100) // Small delay to ensure action completion
            }
            
        } catch (e: Exception) {
            
            throw RuntimeException("Failed to set media URI with subtitles: ${e.message}", e)
        }
    }
    
    /**
     * Check if device supports subtitle track control
     */
    private suspend fun deviceSupportsSubtitleControl(deviceUdn: String): Boolean {
        return try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            // Check if the device has SetCurrentSubtitle action
            val setSubtitleAction = avTransportService.getAction("SetCurrentSubtitle")
            val result = setSubtitleAction != null
            
            
            result
        } catch (e: Exception) {
            
            false
        }
    }

    /**
     * Enhanced method to set media URI with subtitle support check
     */
    suspend fun setMediaUriWithSubtitlesEnhanced(
        deviceUdn: String, 
        uri: String, 
        finalMetadata: String,
        subtitleTracks: List<SubtitleTrack>
    ) {
        
        
        
        
        try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            
            val controlPoint = requireUpnpService().controlPoint
            
            
            // Check if device supports subtitle control
            val supportsSubtitles = deviceSupportsSubtitleControl(deviceUdn)
            
            val metadataToUse = if (supportsSubtitles && subtitleTracks.isNotEmpty()) {
                
                enhanceMetadataWithSubtitles(finalMetadata, subtitleTracks)
            } else {
                if (!supportsSubtitles && subtitleTracks.isNotEmpty()) {
                    
                }
                finalMetadata
            }
            
            val setUriCallback = object : SetAVTransportURI(avTransportService, uri, metadataToUse) {
                override fun success(invocation: ActionInvocation<*>?) {
                    
                }

                override fun failure(
                    invocation: ActionInvocation<*>?,
                    operation: UpnpResponse?,
                    defaultMsg: String?
                ) {
                    val errorMsg = "SetAVTransportURI failed: ${operation?.responseDetails} - $defaultMsg"
                    
                    throw RuntimeException(errorMsg)
                }
            }
            
            controlPoint.execute(setUriCallback)
            withContext(Dispatchers.IO) {
                delay(100) // Small delay to ensure action completion
            }
            
        } catch (e: Exception) {
            
            throw RuntimeException("Failed to set media URI with subtitles: ${e.message}", e)
        }
    }

    /**
     * Enable or disable subtitle track
     */
    suspend fun setSubtitleTrack(deviceUdn: String, subtitleTrackId: String?) {
        
        
        try {
            // First check if the device supports subtitle control
            if (!deviceSupportsSubtitleControl(deviceUdn)) {
                
                throw UnsupportedOperationException("Device does not support subtitle track control")
            }
            
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            val controlPoint = requireUpnpService().controlPoint
            
            // Use SetCurrentSubtitle action
            val setSubtitleAction = avTransportService.getAction("SetCurrentSubtitle")!!
            
            val actionInvocation = ActionInvocation(setSubtitleAction).apply {
                setInput("InstanceID", "0")
                setInput("SubtitleURI", subtitleTrackId ?: "")
            }
            
            val callback = object : ActionCallback(actionInvocation) {
                override fun success(invocation: ActionInvocation<*>?) {
                    
                }

                override fun failure(
                    invocation: ActionInvocation<*>?,
                    operation: UpnpResponse?,
                    defaultMsg: String?
                ) {
                    
                }
            }
            
            controlPoint.execute(callback)
            
        } catch (e: UnsupportedOperationException) {
            // Re-throw UnsupportedOperationException as-is for proper handling
            throw e
        } catch (e: Exception) {
            
            throw RuntimeException("Failed to set subtitle track: ${e.message}", e)
        }
    }
    
    /**
     * Get available subtitle tracks for current media
     */
    suspend fun getAvailableSubtitleTracks(deviceUdn: String): List<SubtitleTrack> {
        
        
        try {
            // First check if the device supports subtitle control
            if (!deviceSupportsSubtitleControl(deviceUdn)) {
                
                return emptyList()
            }
            
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            val controlPoint = requireUpnpService().controlPoint
            
            // Get current media information which may contain subtitle track info
            val positionInfo = controlPoint.getPositionInfoSuspending(avTransportService)
            val metadata = positionInfo?.trackMetaData
            
            if (metadata != null) {
                return parseSubtitleTracksFromMetadata(metadata)
            }
            
            return emptyList()
        } catch (e: Exception) {
            
            return emptyList()
        }
    }
    
    /**
     * Get currently active subtitle track
     */
    suspend fun getCurrentSubtitleTrack(deviceUdn: String): SubtitleTrack? {
        
        
        try {
            // First check if the device supports subtitle control
            if (!deviceSupportsSubtitleControl(deviceUdn)) {
                
                return null
            }
            
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            val controlPoint = requireUpnpService().controlPoint
            
            // Try to get current subtitle info if the device supports it
            val getCurrentSubtitleAction = avTransportService.getAction("GetCurrentSubtitle")
            
            if (getCurrentSubtitleAction != null) {
                val actionInvocation = ActionInvocation(getCurrentSubtitleAction).apply {
                    setInput("InstanceID", "0")
                }
                
                // This would need to be implemented with a synchronous callback
                // For now, return null as most devices don't support this action
                
            }
            
            return null
        } catch (e: Exception) {
            
            return null
        }
    }
    
    /**
     * Parse subtitle tracks from DIDL-Lite metadata
     */
    private fun parseSubtitleTracksFromMetadata(metadata: String): List<SubtitleTrack> {
        return try {
            val parser = DIDLParser()
            val didl = parser.parse(metadata)
            
            val subtitleTracks = mutableListOf<SubtitleTrack>()
            
            if (didl.items.isNotEmpty()) {
                val item = didl.items[0]
                
                item.resources.forEachIndexed { index, resource ->
                    val mimeType = resource.protocolInfo.contentFormat
                    
                    if (mimeType.startsWith("text/")) {
                        // This is likely a subtitle track
                        val track = SubtitleTrack(
                            id = "track_$index",
                            uri = Url(resource.value),
                            mimeType = mimeType,
                            language = extractLanguageFromResource(resource) ?: "unknown",
                            title = extractTitleFromResource(resource),
                            isDefault = index == 0
                        )
                        subtitleTracks.add(track)
                    }
                }
            }
            
            subtitleTracks
        } catch (e: Exception) {
            
            emptyList()
        }
    }
    
    /**
     * Extract language code from resource metadata
     */
    private fun extractLanguageFromResource(resource: Res): String? {
        // This would need to be implemented based on how the DLNA device
        // stores language information in the resource metadata
        return null
    }
    
    /**
     * Extract title from resource metadata
     */
    private fun extractTitleFromResource(resource: Res): String? {
        // This would need to be implemented based on how the DLNA device
        // stores title information in the resource metadata
        return null
    }

    /**
     * Enhance DIDL metadata with subtitle information
     */
    private fun enhanceMetadataWithSubtitles(metadata: String, subtitleTracks: List<SubtitleTrack>): String {
        return try {
            
            
            val parser = DIDLParser()
            val didl = parser.parse(metadata)
            
            // Add subtitle resources to the first item (assuming single item)
            if (didl.items.isNotEmpty()) {
                val item = didl.items[0]
                
                subtitleTracks.forEach { track ->
                    
                    
                    // Create protocol info with proper DLNA profile for subtitles
                    val protocolInfoString = when {
                        track.mimeType.contains("srt") -> "http-get:*:text/srt:DLNA.ORG_PN=TEXT_SRT"
                        track.mimeType.contains("vtt") -> "http-get:*:text/vtt:DLNA.ORG_PN=TEXT_VTT"
                        track.mimeType.contains("sub") -> "http-get:*:text/sub:*"
                        track.mimeType.contains("ass") -> "http-get:*:text/ass:*"
                        else -> "http-get:*:${track.mimeType}:*"
                    }
                    
                    val subtitleResource = Res(
                        ProtocolInfo(protocolInfoString),
                        0L, // Subtitle files don't have duration
                        track.uri.value
                    )
                    
                    // Note: Language attribute would need custom implementation
                    // as the Res class doesn't have a setLanguage method
                    
                    item.addResource(subtitleResource)
                    
                }
            }
            
            val enhancedMetadata = parser.generate(didl, true)
            
            
            
            return enhancedMetadata
        } catch (e: Exception) {
            
            return metadata
        }
    }
    
    /**
     * Public method to check if device supports subtitle control (for debugging)
     */
    suspend fun checkDeviceSubtitleSupport(deviceUdn: String): Boolean {
        return deviceSupportsSubtitleControl(deviceUdn)
    }
    
    /**
     * Debug method to inspect device capabilities
     */
    suspend fun debugDeviceCapabilities(deviceUdn: String): Map<String, Any> {
        val debug = mutableMapOf<String, Any>()
        
        try {
            val (device, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
            
            // Basic device info
            debug["deviceName"] = device.details.friendlyName
            debug["deviceType"] = device.type.toString()
            debug["manufacturer"] = device.details.manufacturerDetails?.manufacturer ?: "Unknown"
            debug["modelName"] = device.details.modelDetails?.modelName ?: "Unknown"
            
            // AVTransport service actions
            val actions = avTransportService.actions.map { it.name }
            debug["availableActions"] = actions
            debug["hasSetCurrentSubtitle"] = actions.contains("SetCurrentSubtitle")
            debug["hasGetCurrentSubtitle"] = actions.contains("GetCurrentSubtitle")
            
            // Check for other subtitle-related actions
            val subtitleActions = actions.filter { it.contains("subtitle", ignoreCase = true) || it.contains("caption", ignoreCase = true) }
            debug["subtitleRelatedActions"] = subtitleActions
            
            
            
        } catch (e: Exception) {
            debug["error"] = e.message ?: "Unknown error"
            
        }
        
        return debug
    }
    
    /**
     * Debug method to inspect generated metadata
     */
    fun debugMetadata(originalMetadata: String, subtitleTracks: List<SubtitleTrack>): Map<String, String> {
        val debug = mutableMapOf<String, String>()
        
        try {
            debug["originalMetadata"] = originalMetadata
            debug["subtitleTracksCount"] = subtitleTracks.size.toString()
            
            if (subtitleTracks.isNotEmpty()) {
                val enhancedMetadata = enhanceMetadataWithSubtitles(originalMetadata, subtitleTracks)
                debug["enhancedMetadata"] = enhancedMetadata
                debug["metadataChanged"] = (originalMetadata != enhancedMetadata).toString()
            }
            
            // Parse and analyze the metadata
            val parser = DIDLParser()
            val didl = parser.parse(originalMetadata)
            
            if (didl.items.isNotEmpty()) {
                val item = didl.items[0]
                debug["itemTitle"] = item.title
                debug["itemClass"] = item.clazz.value
                debug["resourceCount"] = item.resources.size.toString()
                
                val resourceInfo = item.resources.mapIndexed { index, resource ->
                    "Resource $index: ${resource.protocolInfo.contentFormat} - ${resource.value}"
                }
                debug["resources"] = resourceInfo.joinToString("\n")
            }
            
            
            
        } catch (e: Exception) {
            debug["error"] = e.message ?: "Unknown error"
            
        }
        
        return debug
    }
    
    /**
     * Sets playback speed using the standard UPnP Play action with Speed parameter
     */
    suspend fun setPlaybackSpeed(deviceUdn: String, speed: Double) {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val controlPoint = requireUpnpService().controlPoint
        
        // Use the standard Play action which supports Speed parameter
        val playAction = avTransportService.getAction("Play")
            ?: throw UnsupportedOperationException("Play action not available on device $deviceUdn")

//        log each parameter supported and expected by the action
        Log.d("MediaControlManager", "Available parameters for Play action: ${playAction.arguments.joinToString { "${it.name} (${it.datatype.displayString})" }}")
        val speedString = speed.toString()
        
        Log.d("MediaControlManager", "Setting playback speed to $speedString (from $speed) for device $deviceUdn")
        
        val actionInvocation = ActionInvocation(playAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
            setInput("Speed", speedString)
        }
        
        val speedCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                Log.d("MediaControlManager", "Playback speed set to $speedString for device $deviceUdn")
            }
            
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                Log.e("MediaControlManager", "Failed to set playback speed for device $deviceUdn: $defaultMsg")
                // If the device doesn't support speed parameter, throw a more descriptive error
                throw UnsupportedOperationException("Device $deviceUdn does not support playback speed control: $defaultMsg")
            }
        }
        
        controlPoint.executeSuspending(speedCallback)
    }

    /**
     * Returns speed tokens declared by renderer metadata (for example: ["1"], ["1", "2"]).
     * Empty list means the device did not publish explicit supported values.
     */
    suspend fun getSupportedPlaybackSpeeds(deviceUdn: String): List<String> {
        val (_, avTransportService) = requireDeviceAndService(deviceUdn, "AVTransport")
        val playAction = avTransportService.getAction("Play")
            ?: return emptyList()

        val speedArgument = playAction.arguments.firstOrNull {
            it.name.equals("Speed", ignoreCase = true)
        } ?: return emptyList()

        val relatedStateVarName = invokeOptionalGetter(speedArgument, "getRelatedStateVariableName") as? String
            ?: return emptyList()

        val stateVariable = avTransportService.stateVariables.firstOrNull {
            it.name.equals(relatedStateVarName, ignoreCase = true)
        } ?: return emptyList()

        val typeDetails = invokeOptionalGetter(stateVariable, "getTypeDetails")
        val allowedValues = invokeOptionalGetter(typeDetails, "getAllowedValues") as? Array<*>
        val supportedSpeeds = allowedValues
            ?.mapNotNull { it?.toString()?.trim() }
            ?.filter { it.isNotEmpty() }
            ?.distinct()
            ?: emptyList()

        Log.d(
            "MediaControlManager",
            "Device $deviceUdn supported playback speed tokens: ${if (supportedSpeeds.isEmpty()) "<not declared>" else supportedSpeeds.joinToString(", ")}"
        )

        return supportedSpeeds
    }

    private fun invokeOptionalGetter(target: Any?, methodName: String): Any? {
        if (target == null) return null
        return runCatching {
            val method = target.javaClass.methods.firstOrNull {
                it.name == methodName && it.parameterCount == 0
            } ?: return null
            method.invoke(target)
        }.getOrNull()
    }
}


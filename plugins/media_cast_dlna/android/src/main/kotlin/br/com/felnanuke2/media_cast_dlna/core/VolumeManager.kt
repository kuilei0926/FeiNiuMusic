package br.com.felnanuke2.media_cast_dlna.core

import DeviceUdn
import VolumeInfo
import VolumeLevel
import MuteState
import android.util.Log
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.jupnp.android.AndroidUpnpService
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.message.UpnpResponse
import org.jupnp.model.types.UnsignedIntegerFourBytes
import org.jupnp.model.types.UnsignedIntegerTwoBytes
import org.jupnp.controlpoint.ActionCallback

class VolumeManager(upnpService: AndroidUpnpService?) : BaseManager(upnpService) {
    
    /**
     * Sets volume using coroutines
     */
    suspend fun setVolume(deviceUdn: String, volume: Long) {
        val (_, renderingControlService) = requireDeviceAndService(deviceUdn, "RenderingControl")
        val controlPoint = requireUpnpService().controlPoint
        
        val setVolumeAction = renderingControlService.getAction("SetVolume")
            ?: throw IllegalStateException("SetVolume action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(setVolumeAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
            setInput("Channel", "Master")
            setInput("DesiredVolume", UnsignedIntegerTwoBytes(volume))
        }
        
        val setVolumeCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(setVolumeCallback)
    }

    /**
     * Gets volume info using coroutines (runs volume and mute queries concurrently)
     */
    suspend fun getVolumeInfo(deviceUdn: DeviceUdn): VolumeInfo = coroutineScope {
        val (_, renderingControlService) = requireDeviceAndService(deviceUdn.value, "RenderingControl")
        val controlPoint = requireUpnpService().controlPoint
        
        try {
            // Execute both queries concurrently for better performance
            val volumeDeferred = async { 
                controlPoint.getVolumeSuspending(renderingControlService) 
            }
            val muteDeferred = async { 
                controlPoint.getMuteSuspending(renderingControlService) 
            }
            
            val volume = volumeDeferred.await()
            val muted = muteDeferred.await()
            
            VolumeInfo(VolumeLevel(volume.toLong()), MuteState(muted))
        } catch (e: Exception) {
            
            VolumeInfo(VolumeLevel(0), MuteState(false))
        }
    }

    /**
     * Sets mute state using coroutines
     */
    suspend fun setMute(deviceUdn: String, muted: Boolean) {
        val (_, renderingControlService) = requireDeviceAndService(deviceUdn, "RenderingControl")
        val controlPoint = requireUpnpService().controlPoint
        
        val setMuteAction = renderingControlService.getAction("SetMute")
            ?: throw IllegalStateException("SetMute action not available on device $deviceUdn")
        
        val actionInvocation = ActionInvocation(setMuteAction).apply {
            setInput("InstanceID", UnsignedIntegerFourBytes(0))
            setInput("Channel", "Master")
            setInput("DesiredMute", muted)
        }
        
        val setMuteCallback = object : ActionCallback(actionInvocation) {
            override fun success(invocation: ActionInvocation<*>?) {
                
            }
            override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {
                
            }
        }
        
        controlPoint.executeSuspending(setMuteCallback)
    }
}


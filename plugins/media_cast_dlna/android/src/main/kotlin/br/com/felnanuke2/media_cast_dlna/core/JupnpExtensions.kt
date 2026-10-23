package br.com.felnanuke2.media_cast_dlna.core

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import org.jupnp.controlpoint.ActionCallback
import org.jupnp.controlpoint.ControlPoint
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.message.UpnpResponse
import org.jupnp.model.meta.Service
import org.jupnp.support.avtransport.callback.GetPositionInfo
import org.jupnp.support.avtransport.callback.GetTransportInfo
import org.jupnp.support.model.PositionInfo
import org.jupnp.support.model.TransportInfo
import org.jupnp.support.renderingcontrol.callback.GetVolume
import org.jupnp.support.renderingcontrol.callback.GetMute
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

suspend fun <T : ActionCallback> ControlPoint.executeSuspending(
    callback: T,
    timeoutMs: Long = 15000,
): T = diagnoseAction(callback.actionInvocation.action.name) { started ->
    withTimeout(timeoutMs) {
        suspendCancellableCoroutine { continuation ->
            val originalCallback = object : ActionCallback(callback.actionInvocation) {
                override fun success(invocation: ActionInvocation<*>?) {
                    if (!continuation.isActive) return
                    try {
                        callback.success(invocation)
                        continuation.resume(callback)
                    } catch (error: Exception) {
                        continuation.resumeWithException(error)
                    }
                }

                override fun failure(
                    invocation: ActionInvocation<*>?,
                    response: UpnpResponse?,
                    defaultMsg: String?,
                ) {
                    if (!continuation.isActive) return
                    continuation.resumeWithException(
                        actionFailure(callback.actionInvocation.action.name, started, invocation, response)
                    )
                }
            }
            try {
                execute(originalCallback)
            } catch (error: Exception) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }
        }
    }
}

suspend fun ControlPoint.getPositionInfoSuspending(
    service: Service<*, *>,
    timeoutMs: Long = 5000,
): PositionInfo? {
    var result: PositionInfo? = null
    executeSuspending(object : GetPositionInfo(service) {
        override fun received(invocation: ActionInvocation<*>?, info: PositionInfo?) {
            result = info
        }

        override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {}
    }, timeoutMs)
    return result
}

suspend fun ControlPoint.getTransportInfoSuspending(
    service: Service<*, *>,
    timeoutMs: Long = 5000,
): TransportInfo? {
    var result: TransportInfo? = null
    executeSuspending(object : GetTransportInfo(service) {
        override fun received(invocation: ActionInvocation<*>?, info: TransportInfo?) {
            result = info
        }

        override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {}
    }, timeoutMs)
    return result
}

suspend fun ControlPoint.getVolumeSuspending(
    service: Service<*, *>,
    timeoutMs: Long = 5000,
): Int {
    var result = 0
    executeSuspending(object : GetVolume(service) {
        override fun received(invocation: ActionInvocation<*>?, currentVolume: Int) {
            result = currentVolume
        }

        override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {}
    }, timeoutMs)
    return result
}

suspend fun ControlPoint.getMuteSuspending(
    service: Service<*, *>,
    timeoutMs: Long = 5000,
): Boolean {
    var result = false
    executeSuspending(object : GetMute(service) {
        override fun received(invocation: ActionInvocation<*>?, currentMute: Boolean) {
            result = currentMute
        }

        override fun failure(invocation: ActionInvocation<*>?, operation: UpnpResponse?, defaultMsg: String?) {}
    }, timeoutMs)
    return result
}

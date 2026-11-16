package com.feiniu.music

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.jupnp.android.AndroidUpnpService
import org.jupnp.android.AndroidUpnpServiceImpl
import org.jupnp.controlpoint.ActionCallback
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.message.UpnpResponse
import org.jupnp.model.types.ServiceType
import org.jupnp.model.types.UDN

/** Query the existing UPnP registry without changing the third-party plugin. */
class DlnaCapabilitiesBridge(context: Context) {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())

    fun query(udn: String, result: MethodChannel.Result) {
        var finished = false
        var bound = false
        lateinit var connection: ServiceConnection
        lateinit var timeout: Runnable
        fun finish(sink: String?) {
            handler.post {
                if (!finished) {
                    finished = true
                    handler.removeCallbacks(timeout)
                    if (bound) {
                        context.unbindService(connection)
                        bound = false
                    }
                    result.success(sink)
                }
            }
        }
        timeout = Runnable { finish(null) }
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (finished) return
                try {
                    val upnp = binder as AndroidUpnpService
                    val device = upnp.registry.getDevice(UDN.valueOf(udn), false)
                    val service = device?.findService(
                        ServiceType.valueOf("urn:schemas-upnp-org:service:ConnectionManager:1")
                    )
                    val action = service?.getAction("GetProtocolInfo")
                    if (action == null) {
                        finish(null)
                        return
                    }
                    upnp.controlPoint.execute(object : ActionCallback(ActionInvocation(action)) {
                        override fun success(invocation: ActionInvocation<*>?) {
                            finish(invocation?.getOutput("Sink")?.value?.toString())
                        }
                        override fun failure(
                            invocation: ActionInvocation<*>?,
                            operation: UpnpResponse?,
                            defaultMsg: String?
                        ) { finish(null) }
                    })
                } catch (_: Exception) { finish(null) }
            }
            override fun onServiceDisconnected(name: ComponentName) { finish(null) }
        }
        handler.postDelayed(timeout, 5000)
        try {
            bound = context.bindService(
                Intent(context, AndroidUpnpServiceImpl::class.java), connection, Context.BIND_AUTO_CREATE
            )
            if (!bound) finish(null)
        } catch (_: Exception) { finish(null) }
    }
}

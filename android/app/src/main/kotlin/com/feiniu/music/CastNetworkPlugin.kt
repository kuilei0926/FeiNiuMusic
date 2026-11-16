package com.feiniu.music

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** The Dart media proxy and renderer polling still need Wi-Fi during remote playback. */
class CastNetworkPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Suppress("DEPRECATION")
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val wifiManager = binding.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        wifiLock = wifiManager?.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "feiniu:dlna-network"
        )?.apply { setReferenceCounted(false) }
        channel = MethodChannel(binding.binaryMessenger, "com.feiniu.music/cast_network").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "setActive") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val lock = wifiLock
                    if (call.argument<Boolean>("active") == true) {
                        if (lock != null && !lock.isHeld) lock.acquire()
                    } else {
                        releaseLock()
                    }
                    result.success(null)
                } catch (error: SecurityException) {
                    result.error("cast_network_permission", error.message, null)
                }
            }
        }
    }

    private fun releaseLock() {
        wifiLock?.let { if (it.isHeld) it.release() }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        releaseLock()
        wifiLock = null
    }
}

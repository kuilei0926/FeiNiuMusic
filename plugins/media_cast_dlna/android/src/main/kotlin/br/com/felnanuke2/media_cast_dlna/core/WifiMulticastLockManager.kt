package br.com.felnanuke2.media_cast_dlna.core

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log

/**
 * Manages WifiMulticastLock for DLNA device discovery.
 * 
 * Without this lock, many Android ROMs filter multicast packets silently,
 * causing device discovery to fail completely. This manager ensures the lock
 * is acquired when discovery starts and released when stopped.
 */
class WifiMulticastLockManager(private val context: Context) {
    companion object {
        private const val TAG = "WifiMulticastLockManager"
        private const val LOCK_TAG = "MediaCastDlna"
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private val wifiManager: WifiManager by lazy {
        context.getSystemService(Context.WIFI_SERVICE) as WifiManager
    }

    /**
     * Acquires the WiFi multicast lock.
     * Safe to call multiple times - subsequent calls are ignored if lock is already held.
     */
    fun acquireMulticastLock() {
        try {
            if (multicastLock == null) {
                multicastLock = wifiManager.createMulticastLock(LOCK_TAG)
                multicastLock?.acquire()
                Log.d(TAG, "WiFi multicast lock acquired")
            } else if (!(multicastLock?.isHeld == true)) {
                multicastLock?.acquire()
                Log.d(TAG, "WiFi multicast lock re-acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire WiFi multicast lock", e)
        }
    }

    /**
     * Releases the WiFi multicast lock.
     * Safe to call if lock is not held or already released.
     */
    fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
                Log.d(TAG, "WiFi multicast lock released")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release WiFi multicast lock", e)
        }
    }

    /**
     * Checks if the multicast lock is currently held.
     */
    fun isLockHeld(): Boolean {
        return multicastLock?.isHeld == true
    }

    /**
     * Cleans up resources. Should be called when the plugin is detached.
     */
    fun cleanup() {
        releaseMulticastLock()
        multicastLock = null
    }
}

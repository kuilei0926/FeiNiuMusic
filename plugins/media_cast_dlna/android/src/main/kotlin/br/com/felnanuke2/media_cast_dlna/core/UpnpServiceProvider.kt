package br.com.felnanuke2.media_cast_dlna.core

import org.jupnp.android.AndroidUpnpService

interface UpnpServiceProvider {
    fun getUpnpService(): AndroidUpnpService?
}

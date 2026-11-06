package br.com.felnanuke2.media_cast_dlna

import FlutterError
import br.com.felnanuke2.media_cast_dlna.core.DlnaActionException

internal fun dlnaPlatformError(error: Throwable): Throwable =
    if (error is DlnaActionException) {
        FlutterError("dlna_action_failed", error.message, error.details())
    } else {
        error
    }

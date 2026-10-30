package br.com.felnanuke2.media_cast_dlna.core

import org.jupnp.model.UnsupportedDataException
import org.jupnp.support.model.PositionInfo

internal fun parsePositionInfo(values: Map<String, Any?>): PositionInfo {
    fun text(name: String, fallback: String? = null): String {
        val value = values[name]
        if (value is String) return value
        return fallback ?: throw UnsupportedDataException("Invalid position field: $name")
    }

    fun integer(name: String, fallback: Long): Long =
        values[name]?.toString()?.toLongOrNull() ?: fallback

    return PositionInfo(
        integer("Track", 0).takeIf { it in 0..0xffffffffL } ?: 0,
        text("TrackDuration"),
        text("TrackMetaData", ""),
        text("TrackURI", ""),
        text("RelTime"),
        text("AbsTime", "NOT_IMPLEMENTED"),
        integer("RelCount", Int.MAX_VALUE.toLong()).takeIf {
            it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()
        }?.toInt() ?: Int.MAX_VALUE,
        integer("AbsCount", Int.MAX_VALUE.toLong()).takeIf {
            it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()
        }?.toInt() ?: Int.MAX_VALUE,
    )
}

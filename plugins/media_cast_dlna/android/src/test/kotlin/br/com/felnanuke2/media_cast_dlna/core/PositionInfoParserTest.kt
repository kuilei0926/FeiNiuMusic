package br.com.felnanuke2.media_cast_dlna.core

import kotlinx.coroutines.runBlocking
import org.jupnp.controlpoint.ActionCallback
import org.jupnp.controlpoint.ControlPoint
import org.jupnp.model.UnsupportedDataException
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.action.ActionArgumentValue
import org.jupnp.model.meta.Action
import org.jupnp.model.meta.ActionArgument
import org.jupnp.model.meta.RemoteService
import org.jupnp.model.meta.StateVariable
import org.jupnp.model.meta.StateVariableTypeDetails
import org.jupnp.model.types.Datatype
import org.jupnp.model.types.ServiceType
import org.jupnp.model.types.UDAServiceId
import org.jupnp.support.model.PositionInfo
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import java.net.URI

class PositionInfoParserTest {
    private fun service(trackType: Datatype.Builtin, counterType: Datatype.Builtin): RemoteService {
        val types = linkedMapOf(
            "InstanceID" to Datatype.Builtin.UI4,
            "Track" to trackType,
            "TrackDuration" to Datatype.Builtin.STRING,
            "TrackMetaData" to Datatype.Builtin.STRING,
            "TrackURI" to Datatype.Builtin.STRING,
            "RelTime" to Datatype.Builtin.STRING,
            "AbsTime" to Datatype.Builtin.STRING,
            "RelCount" to counterType,
            "AbsCount" to counterType,
        )
        val arguments = types.keys.map { name ->
            ActionArgument<RemoteService>(name, name, if (name == "InstanceID") {
                ActionArgument.Direction.IN
            } else ActionArgument.Direction.OUT)
        }.toTypedArray()
        return RemoteService(
            ServiceType("schemas-upnp-org", "AVTransport", 1), UDAServiceId("AVTransport"),
            URI("/scpd"), URI("/control"), URI("/events"),
            arrayOf(Action("GetPositionInfo", arguments)),
            types.map { (name, type) ->
                StateVariable<RemoteService>(name, StateVariableTypeDetails(type.datatype))
            }.toTypedArray(),
        )
    }

    @Test
    fun actualCallbackAcceptsStringTracksAndUnsignedCounters() {
        for ((trackType, counterType) in listOf(
            Datatype.Builtin.UI4 to Datatype.Builtin.I4,
            Datatype.Builtin.STRING to Datatype.Builtin.STRING,
            Datatype.Builtin.UI4 to Datatype.Builtin.UI4,
        )) {
            val service = service(trackType, counterType)
            val controlPoint = Mockito.mock(ControlPoint::class.java)
            Mockito.doAnswer { call ->
                val callback = call.getArgument<ActionCallback>(0)
                val invocation = callback.actionInvocation
                mapOf(
                    "Track" to "1", "TrackDuration" to "00:04:14",
                    "TrackMetaData" to "", "TrackURI" to "http://renderer/media.flac",
                    "RelTime" to "00:00:02", "AbsTime" to "NOT_IMPLEMENTED",
                    "RelCount" to "0", "AbsCount" to "0",
                ).forEach { (name, value) -> invocation.setOutput(name, value) }
                if (trackType != Datatype.Builtin.UI4 || counterType != Datatype.Builtin.I4) {
                    val outputs: Map<String, ActionArgumentValue<*>> = invocation.outputMap.mapValues { it.value }
                    assertThrows(ClassCastException::class.java) { PositionInfo(outputs) }
                }
                callback.success(invocation)
                null
            }.`when`(controlPoint).execute(Mockito.any(ActionCallback::class.java))
            val info = runBlocking { controlPoint.getPositionInfoSuspending(service) }!!
            assertEquals(1L, info.track.value)
            assertEquals("00:04:14", info.trackDuration)
            assertEquals("00:00:02", info.relTime)
            assertEquals(0, info.relCount)
        }
    }

    @Test
    fun optionalCountersAndMetadataCanBeUnimplemented() {
        val info = parsePositionInfo(mapOf(
            "TrackDuration" to "00:04:14", "RelTime" to "00:00:02",
            "RelCount" to "NOT_IMPLEMENTED", "AbsCount" to 0xffffffffL,
        ))
        assertEquals(Int.MAX_VALUE, info.relCount)
        assertEquals(Int.MAX_VALUE, info.absCount)
        assertEquals("00:00:02", info.relTime)
    }

    @Test
    fun missingProgressDoesNotBecomeAStoppedFrame() {
        val error = assertThrows(UnsupportedDataException::class.java) {
            parsePositionInfo(mapOf("TrackDuration" to "00:04:14"))
        }
        assertEquals("invalid_response", DlnaActionException.from(
            "GetPositionInfo", System.nanoTime(), error,
        ).category)
        assertEquals("invalid_response", DlnaActionException.from(
            "GetPositionInfo", System.nanoTime(), ClassCastException(),
        ).category)
    }
}

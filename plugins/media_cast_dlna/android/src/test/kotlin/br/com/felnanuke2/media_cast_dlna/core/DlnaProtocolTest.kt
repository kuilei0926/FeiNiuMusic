package br.com.felnanuke2.media_cast_dlna.core

import AudioMetadata
import FlutterError
import br.com.felnanuke2.media_cast_dlna.dlnaPlatformError
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import org.jupnp.controlpoint.ActionCallback
import org.jupnp.controlpoint.ControlPoint
import org.jupnp.model.action.ActionException
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.UnsupportedDataException
import org.jupnp.model.message.UpnpResponse
import org.jupnp.model.meta.Action
import org.jupnp.model.meta.RemoteService
import org.mockito.Mockito
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.jupnp.support.contentdirectory.DIDLParser
import org.xml.sax.SAXParseException
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CancellationException

class DlnaProtocolTest {
    @Test
    fun playlistAndAudioTypesIgnoreQueryAndFragment() {
        val types = mapOf(
            "playlist.M3U8?signature=file.mp3#fragment.flac" to "application/vnd.apple.mpegurl",
            "song.flac?token=file.mp3" to "audio/flac",
            "song.m4a" to "audio/mp4",
            "song.opus" to "audio/ogg",
            "song.dsf" to "audio/x-dsf",
            "song.ape" to "audio/x-ape",
            "segment.ts?signature=x" to "video/mp2t",
            "unknown.bin" to "application/octet-stream",
            "no-extension" to "application/octet-stream",
        )
        for ((path, type) in types) assertEquals(type, mediaMimeType("http://speaker/$path", "audio"))
    }

    @Test
    fun didlUsesActualPlaylistTypeAndEscapesMetadata() {
        val uri = "http://speaker/playlist.m3u8?first=1&second=2"
        val xml = DefaultDidlMetadataConverter().toDidlLite(
            AudioMetadata(title = "A & B <live>", artist = "Artist & Co"), uri,
        )
        val item = DIDLParser().parse(xml).items.single()
        assertEquals("A & B <live>", item.title)
        assertEquals(uri, item.resources.single().value)
        assertEquals("application/vnd.apple.mpegurl", item.resources.single().protocolInfo.contentFormat)
    }

    @Test
    fun structuredErrorSurvivesFlutterBridgeAndExcludesSensitiveMessages() {
        val original = DlnaActionException.from(
            "SetAVTransportURI", System.nanoTime(),
            IOException("http://host/stream?token=secret Cookie: secret"), 714, 500,
        )
        val error = dlnaPlatformError(original) as FlutterError
        val details = error.details as Map<*, *>
        assertEquals("dlna_action_failed", error.code)
        assertEquals(714, details["upnpCode"])
        assertEquals(500, details["httpStatus"])
        assertEquals("SetAVTransportURI", details["action"])
        assertEquals("upnp_fault", details["category"])
        assertFalse(error.message.orEmpty().contains("secret"))
        assertFalse(details.toString().contains("secret"))
    }

    @Test
    fun parserErrorsAreNotReportedAsFormatFaults() {
        val error = DlnaActionException.from(
            "GetTransportInfo", System.nanoTime(),
            SAXParseException("invalid XML", null), 501, 200,
        )
        assertEquals("invalid_response", error.category)
        assertEquals(listOf("SAXParseException"), error.causeTypes)
        assertEquals("invalid_response", DlnaActionException.from(
            "Play", System.nanoTime(), UnsupportedDataException("missing action response"), 501, 200,
        ).category)
    }

    @Test
    fun networkTimeoutAndHttpErrorsRemainDistinct() {
        val started = System.nanoTime()
        assertEquals("timeout", DlnaActionException.from("Play", started, SocketTimeoutException()).category)
        assertEquals("network", DlnaActionException.from("Play", started, IOException()).category)
        assertEquals("http_error", DlnaActionException.from("Play", started, httpStatus = 503).category)
        assertEquals("action_failed", DlnaActionException.from("Play", started).category)
        assertEquals("upnp_fault", DlnaActionException.from("Play", started, upnpCode = 501).category)
    }

    @Test
    fun timeoutPreservesActionAndElapsedTime() {
        val error = assertThrows(DlnaActionException::class.java) {
            runBlocking {
                diagnoseAction("Play") { withTimeout(25) { delay(5000) } }
            }
        }
        assertEquals("Play", error.action)
        assertEquals("timeout", error.category)
        assertTrue(error.elapsedMs >= 20)
    }

    @Test
    fun externalCancellationIsNotReclassifiedAsDeviceFailure() {
        assertThrows(CancellationException::class.java) {
            runBlocking { diagnoseAction("Play") { throw CancellationException("cancelled") } }
        }
    }

    @Test
    fun parentTimeoutRemainsCancellation() {
        assertThrows(TimeoutCancellationException::class.java) {
            runBlocking { withTimeout(25) { diagnoseAction("Play") { delay(5000) } } }
        }
    }

    @Test
    fun actualActionFaultRetainsSoapCodeAndHttpStatus() {
        val controlPoint = Mockito.mock(ControlPoint::class.java)
        val invocation = ActionInvocation(Action<RemoteService>("Play", emptyArray()))
        invocation.failure = ActionException(714, "Illegal MIME-type")
        Mockito.doAnswer { call ->
            val callback = call.getArgument<ActionCallback>(0)
            callback.failure(invocation, UpnpResponse(500, "Internal Server Error"), "failed")
            null
        }.`when`(controlPoint).execute(Mockito.any(ActionCallback::class.java))
        val callback = object : ActionCallback(invocation) {
            override fun success(result: ActionInvocation<*>?) {}
            override fun failure(result: ActionInvocation<*>?, response: UpnpResponse?, message: String?) {}
        }
        val error = assertThrows(DlnaActionException::class.java) {
            runBlocking { controlPoint.executeSuspending(callback) }
        }
        assertEquals("Play", error.action)
        assertEquals(714, error.upnpCode)
        assertEquals(500, error.httpStatus)
    }

    @Test
    fun callbacksAfterTimeoutCannotResumeOrMutateTheOldOperation() {
        val controlPoint = Mockito.mock(ControlPoint::class.java)
        val invocation = ActionInvocation(Action<RemoteService>("Play", emptyArray()))
        var received: ActionCallback? = null
        var successes = 0
        Mockito.doAnswer { call ->
            received = call.getArgument<ActionCallback>(0)
            null
        }.`when`(controlPoint).execute(Mockito.any(ActionCallback::class.java))
        val callback = object : ActionCallback(invocation) {
            override fun success(result: ActionInvocation<*>?) { successes++ }
            override fun failure(result: ActionInvocation<*>?, response: UpnpResponse?, message: String?) {}
        }
        assertThrows(DlnaActionException::class.java) {
            runBlocking { controlPoint.executeSuspending(callback, timeoutMs = 25) }
        }
        received!!.success(invocation)
        received!!.failure(invocation, null, "late failure")
        assertEquals(0, successes)
    }
}

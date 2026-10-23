package br.com.felnanuke2.media_cast_dlna.core

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import org.jupnp.model.action.ActionInvocation
import org.jupnp.model.UnsupportedDataException
import org.jupnp.model.message.UpnpResponse
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CancellationException

internal class DlnaActionException(
    val action: String,
    val category: String,
    val elapsedMs: Long,
    val upnpCode: Int? = null,
    val httpStatus: Int? = null,
    val causeTypes: List<String> = emptyList(),
) : RuntimeException("$action failed ($category)") {
    fun details(): Map<String, Any?> = mapOf(
        "action" to action,
        "category" to category,
        "elapsedMs" to elapsedMs,
        "upnpCode" to upnpCode,
        "httpStatus" to httpStatus,
        "causeTypes" to causeTypes,
    )

    companion object {
        fun from(
            action: String,
            started: Long,
            failure: Throwable? = null,
            upnpCode: Int? = null,
            httpStatus: Int? = null,
        ): DlnaActionException {
            val causes = generateSequence(failure) { it.cause }.take(8).toList()
            val category = when {
                causes.any { it is TimeoutCancellationException || it is SocketTimeoutException } -> "timeout"
                causes.any {
                    val name = it.javaClass.name.lowercase()
                    it is UnsupportedDataException || name.contains("xml") ||
                        name.contains("sax") || name.contains("parser")
                } -> "invalid_response"
                upnpCode != null && upnpCode in 400..899 -> "upnp_fault"
                causes.any { it is IOException } -> "network"
                httpStatus != null && httpStatus !in 200..299 -> "http_error"
                else -> "action_failed"
            }
            return DlnaActionException(
                action, category, (System.nanoTime() - started) / 1_000_000,
                upnpCode, httpStatus, causes.map { it.javaClass.simpleName },
            )
        }
    }
}

internal fun actionFailure(
    action: String,
    started: Long,
    invocation: ActionInvocation<*>?,
    response: UpnpResponse?,
): DlnaActionException = DlnaActionException.from(
    action, started, invocation?.failure, invocation?.failure?.errorCode, response?.statusCode,
)

internal suspend fun <T> diagnoseAction(action: String, block: suspend (Long) -> T): T {
    val started = System.nanoTime()
    try {
        return block(started)
    } catch (error: DlnaActionException) {
        throw error
    } catch (error: TimeoutCancellationException) {
        if (!currentCoroutineContext().isActive) throw error
        throw DlnaActionException.from(action, started, error)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        throw DlnaActionException.from(action, started, error)
    }
}

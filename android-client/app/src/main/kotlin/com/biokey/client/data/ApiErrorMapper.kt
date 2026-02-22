package com.biokey.client.data

import com.biokey.client.model.ApiResult
import org.json.JSONObject

object ApiErrorMapper {
    fun toUserMessage(action: String, result: ApiResult): String {
        if (result.statusCode == -1) {
            return "$action failed: network error"
        }

        val backendMessage = parseBackendMessage(result.body)

        return when (result.statusCode) {
            in 200..299 -> "$action succeeded"
            400 -> "$action failed: invalid request"
            401 -> "$action failed: unauthorized"
            403 -> "$action failed: forbidden"
            404 -> "$action failed: endpoint not found"
            409 -> "$action failed: conflict"
            in 500..599 -> "$action failed: server error"
            else -> "$action failed: HTTP ${result.statusCode}"
        }.let { base ->
            if (backendMessage.isNullOrBlank()) base else "$base ($backendMessage)"
        }
    }

    private fun parseBackendMessage(body: String): String? {
        return try {
            val json = JSONObject(body)
            json.optString("message").takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }
}

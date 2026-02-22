package com.biokey.client.model

import org.json.JSONObject

enum class AppScreen {
    LOGIN,
    TRAIN,
    HOME
}

data class Timing(
    val pair: String,
    val dwell: Float,
    val flight: Float
)

data class ApiResult(
    val statusCode: Int,
    val body: String
)

data class AuthSession(
    val token: String,
    val userId: Int,
    val username: String
)

data class BioKeyUiState(
    val currentScreen: AppScreen = AppScreen.LOGIN,
    val serverUrl: String = "",
    val userId: String = "1",
    val username: String = "",
    val password: String = "",
    val sampleText: String = "",
    val sampleKeyPressTimes: List<Long> = emptyList(),
    val capturedTimings: List<Timing> = emptyList(),
    val resultText: String = "Ready",
    val homeText: String = "Welcome",
    val profileText: String = "Profile not loaded",
    val authToken: String = "",
    val isLoading: Boolean = false
)

fun parseBackendStatus(body: String): String? {
    return try {
        JSONObject(body).optString("status").takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
    }
}

fun parseAuthSession(body: String): AuthSession? {
    return try {
        val json = JSONObject(body)
        val source = if (json.has("token")) json else json.optJSONObject("data") ?: json
        val token = source.optString("token", "")
        val userId = source.optInt("user_id", -1)
        val username = source.optString("username", "")
        if (token.isBlank() || userId <= 0 || username.isBlank()) {
            null
        } else {
            AuthSession(token = token, userId = userId, username = username)
        }
    } catch (_: Exception) {
        null
    }
}

fun parseProfileSummary(body: String): String {
    return try {
        val json = JSONObject(body)
        val username = json.optString("username", "unknown")
        val pairs = json.optInt("biometric_pairs", 0)
        "User: $username | Biometric pairs: $pairs"
    } catch (_: Exception) {
        body
    }
}

fun normalizeTextForCapture(value: String): String {
    return value.lowercase().filter { it.isLetterOrDigit() }
}

fun updateKeyPressTimes(
    previousText: String,
    nextText: String,
    previousPressTimes: List<Long>,
    nowMillis: Long
): List<Long> {
    val oldNorm = normalizeTextForCapture(previousText)
    val newNorm = normalizeTextForCapture(nextText)

    if (newNorm.isEmpty()) {
        return emptyList()
    }

    var commonPrefixLength = 0
    val minLength = minOf(oldNorm.length, newNorm.length)
    while (commonPrefixLength < minLength && oldNorm[commonPrefixLength] == newNorm[commonPrefixLength]) {
        commonPrefixLength++
    }

    val updated = previousPressTimes.take(commonPrefixLength).toMutableList()
    var timeCursor = if (updated.isEmpty()) nowMillis else maxOf(nowMillis, updated.last() + 1)

    for (index in commonPrefixLength until newNorm.length) {
        updated.add(timeCursor)
        timeCursor += 1
    }

    return updated
}

fun buildTimingsFromCapturedInput(text: String, pressTimes: List<Long>): List<Timing> {
    val normalized = normalizeTextForCapture(text)
    if (normalized.length < 2 || pressTimes.size < normalized.length) {
        return emptyList()
    }

    val timings = mutableListOf<Timing>()
    for (index in 0 until normalized.length - 1) {
        val pair = "${normalized[index]}${normalized[index + 1]}"
        val rawFlight = (pressTimes[index + 1] - pressTimes[index]).toFloat()
        val flight = rawFlight.coerceIn(20f, 500f)
        val dwell = (flight * 0.65f).coerceIn(30f, 220f)
        timings.add(Timing(pair = pair, dwell = dwell, flight = flight))
    }
    return timings
}

package com.biokey.client.data

import com.biokey.client.model.ApiResult
import com.biokey.client.model.Timing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

object BioKeyApiClient {
    suspend fun postTimings(
        baseUrl: String,
        endpoint: String,
        userId: Int,
        timings: List<Timing>
    ): ApiResult = withContext(Dispatchers.IO) {
        val trimmed = baseUrl.trimEnd('/')
        val url = URL("$trimmed$endpoint")
        val connection = (url.openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")

            val jsonTimings = JSONArray()
            for (timing in timings) {
                jsonTimings.put(
                    JSONObject()
                        .put("pair", timing.pair)
                        .put("dwell", timing.dwell)
                        .put("flight", timing.flight)
                )
            }

            val payload = JSONObject()
                .put("user_id", userId)
                .put("timings", jsonTimings)

            connection.outputStream.bufferedWriter().use { writer ->
                writer.write(payload.toString())
            }

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = responseStream?.let {
                BufferedReader(InputStreamReader(it)).use { reader -> reader.readText() }
            } ?: ""

            ApiResult(statusCode = statusCode, body = responseBody)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        } finally {
            connection.disconnect()
        }
    }

    suspend fun postAuthCredential(
        baseUrl: String,
        endpoint: String,
        username: String,
        password: String
    ): ApiResult = withContext(Dispatchers.IO) {
        val trimmed = baseUrl.trimEnd('/')
        val url = URL("$trimmed$endpoint")
        val connection = (url.openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")

            val payload = JSONObject()
                .put("username", username)
                .put("password", password)

            connection.outputStream.bufferedWriter().use { writer ->
                writer.write(payload.toString())
            }

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = responseStream?.let {
                BufferedReader(InputStreamReader(it)).use { reader -> reader.readText() }
            } ?: ""

            ApiResult(statusCode = statusCode, body = responseBody)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        } finally {
            connection.disconnect()
        }
    }

    suspend fun getAuthProfile(baseUrl: String, token: String): ApiResult = withContext(Dispatchers.IO) {
        val trimmed = baseUrl.trimEnd('/')
        val url = URL("$trimmed/auth/profile")
        val connection = (url.openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $token")

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = responseStream?.let {
                BufferedReader(InputStreamReader(it)).use { reader -> reader.readText() }
            } ?: ""

            ApiResult(statusCode = statusCode, body = responseBody)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        } finally {
            connection.disconnect()
        }
    }

    suspend fun postAuthLogout(baseUrl: String, token: String): ApiResult = withContext(Dispatchers.IO) {
        val trimmed = baseUrl.trimEnd('/')
        val url = URL("$trimmed/auth/logout")
        val connection = (url.openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $token")

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = responseStream?.let {
                BufferedReader(InputStreamReader(it)).use { reader -> reader.readText() }
            } ?: ""

            ApiResult(statusCode = statusCode, body = responseBody)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        } finally {
            connection.disconnect()
        }
    }
}

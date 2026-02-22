package com.biokey.client.data

import com.biokey.client.model.ApiResult
import com.biokey.client.model.Timing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object BioKeyApiClient {
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    private val okHttpClient: OkHttpClient by lazy {
        val logger = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
        }
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .addInterceptor(logger)
            .build()
    }

    suspend fun postTimings(
        baseUrl: String,
        endpoint: String,
        userId: Int,
        timings: List<Timing>
    ): ApiResult = withContext(Dispatchers.IO) {
        val payload = JSONObject().put("user_id", userId)
        val jsonTimings = JSONArray()
        for (timing in timings) {
            jsonTimings.put(
                JSONObject()
                    .put("pair", timing.pair)
                    .put("dwell", timing.dwell)
                    .put("flight", timing.flight)
            )
        }
        payload.put("timings", jsonTimings)

        execute(
            request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}$endpoint")
                .post(payload.toString().toRequestBody(jsonMediaType))
                .addHeader("Accept", "application/json")
                .build()
        )
    }

    suspend fun postAuthCredential(
        baseUrl: String,
        endpoint: String,
        username: String,
        password: String
    ): ApiResult = withContext(Dispatchers.IO) {
        val payload = JSONObject()
            .put("username", username)
            .put("password", password)

        execute(
            request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}$endpoint")
                .post(payload.toString().toRequestBody(jsonMediaType))
                .addHeader("Accept", "application/json")
                .build()
        )
    }

    suspend fun getAuthProfile(baseUrl: String, token: String): ApiResult = withContext(Dispatchers.IO) {
        execute(
            request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/auth/profile")
                .get()
                .addHeader("Accept", "application/json")
                .addHeader("Authorization", "Bearer $token")
                .build()
        )
    }

    suspend fun postAuthLogout(baseUrl: String, token: String): ApiResult = withContext(Dispatchers.IO) {
        execute(
            request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/auth/logout")
                .post("".toRequestBody(null))
                .addHeader("Accept", "application/json")
                .addHeader("Authorization", "Bearer $token")
                .build()
        )
    }

    private fun execute(request: Request): ApiResult {
        try {
            okHttpClient.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                return ApiResult(statusCode = response.code, body = body)
            }
        } catch (exception: Exception) {
            return ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        }
    }
}

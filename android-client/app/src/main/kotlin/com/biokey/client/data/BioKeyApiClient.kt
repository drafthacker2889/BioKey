package com.biokey.client.data

import com.biokey.client.model.ApiResult
import com.biokey.client.model.Timing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
import retrofit2.Retrofit
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap

object BioKeyApiClient {
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

    private val serviceCache = ConcurrentHashMap<String, BioKeyRetrofitService>()

    private fun normalizeBaseUrl(baseUrl: String): String {
        val trimmed = baseUrl.trim().trimEnd('/')
        return if (trimmed.endsWith("/v1")) "$trimmed/" else "$trimmed/v1/"
    }

    private fun serviceFor(baseUrl: String): BioKeyRetrofitService {
        val normalized = normalizeBaseUrl(baseUrl)
        return serviceCache.getOrPut(normalized) {
            Retrofit.Builder()
                .baseUrl(normalized)
                .client(okHttpClient)
                .build()
                .create(BioKeyRetrofitService::class.java)
        }
    }

    private suspend fun execute(call: suspend () -> Response<okhttp3.ResponseBody>): ApiResult =
        withContext(Dispatchers.IO) {
            try {
                val response = call()
                val body = response.body()?.string().orEmpty().ifBlank {
                    response.errorBody()?.string().orEmpty()
                }
                ApiResult(statusCode = response.code(), body = body)
            } catch (exception: Exception) {
                ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
            }
        }

    suspend fun postTimings(
        baseUrl: String,
        endpoint: String,
        userId: Int,
        timings: List<Timing>
    ): ApiResult {
        val service = serviceFor(baseUrl)
        val payload = TimingPayload(user_id = userId, timings = timings)
        return when (endpoint) {
            "/train" -> execute { service.postTrain(payload) }
            "/login" -> execute { service.postBiometricLogin(payload) }
            else -> ApiResult(statusCode = -1, body = "Unsupported endpoint: $endpoint")
        }
    }

    suspend fun postAuthCredential(
        baseUrl: String,
        endpoint: String,
        username: String,
        password: String
    ): ApiResult {
        val service = serviceFor(baseUrl)
        val payload = AuthCredentialPayload(username = username, password = password)
        return when (endpoint) {
            "/auth/register" -> execute { service.postRegister(payload) }
            "/auth/login" -> execute { service.postAuthLogin(payload) }
            else -> ApiResult(statusCode = -1, body = "Unsupported endpoint: $endpoint")
        }
    }

    suspend fun getAuthProfile(baseUrl: String, token: String): ApiResult = executeAuthorized(baseUrl, token) {
        it.getAuthProfile("Bearer $token")
    }

    suspend fun postAuthLogout(baseUrl: String, token: String): ApiResult = executeAuthorized(baseUrl, token) {
        it.postAuthLogout("Bearer $token")
    }

    suspend fun postAuthRefresh(baseUrl: String, token: String): ApiResult = executeAuthorized(baseUrl, token) {
        it.postAuthRefresh("Bearer $token")
    }

    private suspend fun executeAuthorized(
        baseUrl: String,
        token: String,
        call: suspend (BioKeyRetrofitService) -> Response<okhttp3.ResponseBody>
    ): ApiResult = withContext(Dispatchers.IO) {
        try {
            val response = call(serviceFor(baseUrl))
            val body = response.body()?.string().orEmpty().ifBlank {
                response.errorBody()?.string().orEmpty()
            }
            ApiResult(statusCode = response.code(), body = body)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        }
    }
}

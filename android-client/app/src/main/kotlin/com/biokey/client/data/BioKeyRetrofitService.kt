package com.biokey.client.data

import com.biokey.client.model.Timing
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST

data class TimingPayload(
    val user_id: Int,
    val timings: List<Timing>
)

data class AuthCredentialPayload(
    val username: String,
    val password: String
)

interface BioKeyRetrofitService {
    @POST("train")
    suspend fun postTrain(@Body payload: TimingPayload): Response<ResponseBody>

    @POST("login")
    suspend fun postBiometricLogin(@Body payload: TimingPayload): Response<ResponseBody>

    @POST("auth/register")
    suspend fun postRegister(@Body payload: AuthCredentialPayload): Response<ResponseBody>

    @POST("auth/login")
    suspend fun postAuthLogin(@Body payload: AuthCredentialPayload): Response<ResponseBody>

    @GET("auth/profile")
    suspend fun getAuthProfile(): Response<ResponseBody>

    @POST("auth/logout")
    suspend fun postAuthLogout(): Response<ResponseBody>

    @POST("auth/refresh")
    suspend fun postAuthRefresh(): Response<ResponseBody>
}

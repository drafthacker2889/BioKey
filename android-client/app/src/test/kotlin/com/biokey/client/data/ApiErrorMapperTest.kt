package com.biokey.client.data

import com.biokey.client.model.ApiResult
import org.junit.Assert.assertEquals
import org.junit.Test

class ApiErrorMapperTest {
    @Test
    fun toUserMessage_readsTopLevelLegacyMessage() {
        val result = ApiResult(400, "{" + "\"message\":\"bad input\"}")
        assertEquals("Train failed: invalid request (bad input)", ApiErrorMapper.toUserMessage("Train", result))
    }

    @Test
    fun toUserMessage_readsPhase9ErrorEnvelopeMessage() {
        val result = ApiResult(401, "{" + "\"error\":{\"code\":\"UNAUTHORIZED\",\"message\":\"token expired\"}}")
        assertEquals("Profile failed: unauthorized (token expired)", ApiErrorMapper.toUserMessage("Profile", result))
    }

    @Test
    fun toUserMessage_mapsNetworkFailure() {
        val result = ApiResult(-1, "")
        assertEquals("Login failed: network error", ApiErrorMapper.toUserMessage("Login", result))
    }
}

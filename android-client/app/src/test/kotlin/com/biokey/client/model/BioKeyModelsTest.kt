package com.biokey.client.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BioKeyModelsTest {
    @Test
    fun normalizeTextForCapture_filtersNonAlphaNumericAndLowercases() {
        val normalized = normalizeTextForCapture("A-b C_12!")
        assertEquals("abc12", normalized)
    }

    @Test
    fun updateKeyPressTimes_keepsPrefixAndAddsNewTimes() {
        val updated = updateKeyPressTimes(
            previousText = "ab",
            nextText = "abc",
            previousPressTimes = listOf(10L, 20L),
            nowMillis = 30L
        )

        assertEquals(listOf(10L, 20L, 30L), updated)
    }

    @Test
    fun buildTimingsFromCapturedInput_buildsPairTimings() {
        val timings = buildTimingsFromCapturedInput(
            text = "abcd",
            pressTimes = listOf(100L, 170L, 250L, 330L)
        )

        assertEquals(3, timings.size)
        assertEquals("ab", timings[0].pair)
        assertTrue(timings[0].flight in 20f..500f)
        assertTrue(timings[0].dwell in 30f..220f)
    }

    @Test
    fun parseAuthSession_parsesSuccessfulResponse() {
        val session = parseAuthSession("""
            {"status":"SUCCESS","token":"abc123","user_id":7,"username":"alice"}
        """.trimIndent())

        assertNotNull(session)
        assertEquals("abc123", session?.token)
        assertEquals(7, session?.userId)
        assertEquals("alice", session?.username)
    }
}

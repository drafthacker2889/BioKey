package com.biokey

import android.view.MotionEvent
import android.view.View
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import com.google.gson.Gson
import java.io.IOException

class SensorService {
    private var lastReleaseTime = 0L
    private val client = OkHttpClient()
    private val gson = Gson()

    // Replace with your computer's IP address (e.g., 192.168.1.5)
    // Note: 'localhost' won't work from a real phone/emulator
    private val serverUrl = "http://10.0.2.2:4567/login" 

    fun attachToView(view: View, userId: Int) {
        view.setOnTouchListener { v, event ->
            val currentTime = System.currentTimeMillis()

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    if (lastReleaseTime != 0L) {
                        val flightTime = (currentTime - lastReleaseTime).toDouble()
                        // Capture dwell and flight
                        sendDataToServer(userId, 0.0, flightTime) 
                    }
                }
                MotionEvent.ACTION_UP -> {
                    val dwellTime = (event.eventTime - event.downTime).toDouble()
                    lastReleaseTime = event.eventTime
                    sendDataToServer(userId, dwellTime, 0.0)
                }
            }
            false
        }
    }

    private fun sendDataToServer(userId: Int, dwell: Double, flight: Double) {
        val payload = mapOf(
            "user_id" to userId,
            "timings" to listOf(dwell, flight)
        )
        
        val body = gson.toJson(payload).toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url(serverUrl).post(body).build()

        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                e.printStackTrace()
            }

            override fun onResponse(call: Call, response: Response) {
                println("Server Response: ${response.body?.string()}")
            }
        })
    }
}
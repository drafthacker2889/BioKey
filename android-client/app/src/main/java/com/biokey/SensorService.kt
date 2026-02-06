package com.biokey

import android.view.MotionEvent
import android.view.View

class SensorService {
    private var lastReleaseTime = 0L

    fun attachToView(view: View) {
        view.setOnTouchListener { v, event ->
            val currentTime = System.currentTimeMillis()

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    // Flight Time: Gap between releasing the previous key and pressing this one [cite: 25]
                    if (lastReleaseTime != 0L) {
                        val flightTime = currentTime - lastReleaseTime
                        println("Flight Time captured: ${flightTime}ms")
                    }
                }
                MotionEvent.ACTION_UP -> {
                    // Corrected Dwell Time: Duration the current key was held down using precise event timing [cite: 30]
                    val dwellTime = event.eventTime - event.downTime
                    lastReleaseTime = event.eventTime
                    
                    println("Dwell Time captured: ${dwellTime}ms")
                }
            }
            false // Allow the system to still handle the actual key click
        }
    }
}
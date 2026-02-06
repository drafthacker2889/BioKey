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
                    // Flight Time: Gap between releasing previous key and pressing this one
                    if (lastReleaseTime != 0L) {
                        val flightTime = currentTime - lastReleaseTime
                        println("Flight Time captured: ${flightTime}ms") [cite: 25]
                    }
                }
                MotionEvent.ACTION_UP -> {
                    // Dwell Time: Duration the current key was held down
                    val pressTime = event.eventTime
                    val dwellTime = currentTime - pressTime
                    lastReleaseTime = currentTime [cite: 29]
                    
                    println("Dwell Time captured: ${dwellTime}ms") [cite: 30]
                }
            }
            false // Allow the system to still handle the actual key click
        }
    }
}
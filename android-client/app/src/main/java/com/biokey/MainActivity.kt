package com.biokey

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import android.widget.EditText

class MainActivity : AppCompatActivity() {
    private val sensorService = SensorService()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Find the password field from your layout
        val passwordInput = findViewById<EditText>(R.id.authEditText)
        
        // Attach the biometric sensor to the field for User ID 2
        sensorService.attachToView(passwordInput, 2)
    }
}
package com.biokey.client

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.ViewModelProvider
import com.biokey.client.ui.BioKeyApp
import com.biokey.client.ui.theme.BioKeyTheme
import com.biokey.client.viewmodel.BioKeyViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val bioKeyViewModel = ViewModelProvider(this)[BioKeyViewModel::class.java]

        setContent {
            BioKeyTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    BioKeyApp(nativeStatus = stringFromJNI(), viewModel = bioKeyViewModel)
                }
            }
        }
    }

    external fun stringFromJNI(): String

    companion object {
        init {
            System.loadLibrary("biokey-native")
        }
    }
}

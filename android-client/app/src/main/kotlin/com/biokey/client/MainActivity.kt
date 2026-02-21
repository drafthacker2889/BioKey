package com.biokey.client

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.tooling.preview.Preview
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    BioKeyScreen(nativeStatus = stringFromJNI())
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

@Composable
fun BioKeyScreen(nativeStatus: String) {
    val defaultBackendUrl = stringResource(id = R.string.backend_url)
    var serverUrl by rememberSaveable { mutableStateOf(defaultBackendUrl) }
    var userId by rememberSaveable { mutableStateOf("1") }
    var sampleText by rememberSaveable { mutableStateOf("biokey") }
    var resultText by rememberSaveable { mutableStateOf("Ready") }
    var isLoading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(text = "BioKey Client", style = MaterialTheme.typography.headlineSmall)

        OutlinedTextField(
            value = serverUrl,
            onValueChange = { serverUrl = it },
            label = { Text("Server URL") },
            modifier = Modifier.fillMaxWidth()
        )

        OutlinedTextField(
            value = userId,
            onValueChange = { userId = it },
            label = { Text("User ID") },
            modifier = Modifier.fillMaxWidth()
        )

        OutlinedTextField(
            value = sampleText,
            onValueChange = { sampleText = it },
            label = { Text("Sample Text") },
            modifier = Modifier.fillMaxWidth()
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = {
                    val parsedUserId = userId.toIntOrNull()
                    if (parsedUserId == null) {
                        resultText = "User ID must be a number"
                        return@Button
                    }
                    val timings = buildTimings(sampleText)
                    if (timings.isEmpty()) {
                        resultText = "Sample Text must have at least 2 letters/numbers"
                        return@Button
                    }
                    scope.launch {
                        isLoading = true
                        resultText = ApiClient.postTimings(serverUrl, "/train", parsedUserId, timings)
                        isLoading = false
                    }
                }
            ) {
                Text("Train")
            }

            Button(
                onClick = {
                    val parsedUserId = userId.toIntOrNull()
                    if (parsedUserId == null) {
                        resultText = "User ID must be a number"
                        return@Button
                    }
                    val timings = buildTimings(sampleText)
                    if (timings.isEmpty()) {
                        resultText = "Sample Text must have at least 2 letters/numbers"
                        return@Button
                    }
                    scope.launch {
                        isLoading = true
                        resultText = ApiClient.postTimings(serverUrl, "/login", parsedUserId, timings)
                        isLoading = false
                    }
                }
            ) {
                Text("Login")
            }
        }

        if (isLoading) {
            CircularProgressIndicator()
        }

        Text(text = "Result: $resultText")
        Text(text = "Native: $nativeStatus")
    }
}

@Preview(showBackground = true)
@Composable
fun BioKeyPreview() {
    MaterialTheme {
        BioKeyScreen(nativeStatus = "Hello from C++")
    }
}

data class Timing(
    val pair: String,
    val dwell: Float,
    val flight: Float
)

fun buildTimings(sampleText: String): List<Timing> {
    val normalized = sampleText.lowercase().filter { it.isLetterOrDigit() }
    if (normalized.length < 2) {
        return emptyList()
    }

    val timings = mutableListOf<Timing>()
    for (index in 0 until normalized.length - 1) {
        val first = normalized[index]
        val second = normalized[index + 1]
        val dwell = 80f + ((first.code + (index * 7)) % 90)
        val flight = 40f + ((second.code + (index * 11)) % 80)
        timings.add(Timing(pair = "$first$second", dwell = dwell, flight = flight))
    }
    return timings
}

object ApiClient {
    suspend fun postTimings(
        baseUrl: String,
        endpoint: String,
        userId: Int,
        timings: List<Timing>
    ): String = withContext(Dispatchers.IO) {
        val trimmed = baseUrl.trimEnd('/')
        val url = URL("$trimmed$endpoint")
        val connection = (url.openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")

            val jsonTimings = JSONArray()
            for (timing in timings) {
                jsonTimings.put(
                    JSONObject()
                        .put("pair", timing.pair)
                        .put("dwell", timing.dwell)
                        .put("flight", timing.flight)
                )
            }

            val payload = JSONObject()
                .put("user_id", userId)
                .put("timings", jsonTimings)

            connection.outputStream.bufferedWriter().use { writer ->
                writer.write(payload.toString())
            }

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = responseStream?.let {
                BufferedReader(InputStreamReader(it)).use { reader ->
                    reader.readText()
                }
            } ?: ""

            "HTTP $statusCode: $responseBody"
        } catch (exception: Exception) {
            "Request failed: ${exception.message}"
        } finally {
            connection.disconnect()
        }
    }
}

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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.biokey.client.ui.theme.BioKeyTheme
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
            BioKeyTheme {
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
    var resultText by rememberSaveable { mutableStateOf("Ready. Tap Train to create/update profile.") }
    var isLoading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val parsedUserId by remember(userId) { derivedStateOf { userId.toIntOrNull() } }
    val normalizedSample by remember(sampleText) { derivedStateOf { sampleText.lowercase().filter { it.isLetterOrDigit() } } }
    val isSampleValid by remember(normalizedSample) { derivedStateOf { normalizedSample.length >= 2 } }
    val canSubmit by remember(serverUrl, parsedUserId, isSampleValid, isLoading) {
        derivedStateOf {
            serverUrl.startsWith("http://") || serverUrl.startsWith("https://")
        && parsedUserId != null
        && isSampleValid
        && !isLoading
        }
    }

    fun submit(endpoint: String) {
        val safeUserId = parsedUserId
        if (safeUserId == null) {
            resultText = "User ID must be a number"
            return
        }
        val timings = buildTimings(sampleText)
        if (timings.isEmpty()) {
            resultText = "Sample Text must have at least 2 letters/numbers"
            return
        }
        scope.launch {
            isLoading = true
            resultText = ApiClient.postTimings(serverUrl, endpoint, safeUserId, timings)
            isLoading = false
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(text = "BioKey", style = MaterialTheme.typography.headlineMedium)
        Text(
            text = "Train your typing profile, then verify login rhythm.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(text = "Connection", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = serverUrl,
                    onValueChange = { serverUrl = it.trim() },
                    label = { Text("Server URL") },
                    supportingText = { Text("Phone: use PC Wi-Fi IP. Emulator: use 10.0.2.2") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(text = "Input", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = userId,
                    onValueChange = { userId = it.filter { ch -> ch.isDigit() } },
                    label = { Text("User ID") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    supportingText = {
                        if (parsedUserId == null) {
                            Text("Enter a numeric user id")
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = sampleText,
                    onValueChange = { sampleText = it },
                    label = { Text("Sample Text") },
                    supportingText = { Text("Needs at least 2 letters/numbers. Current pairs: ${buildTimings(sampleText).size}") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Button(
                onClick = { submit("/train") },
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Train")
            }
            Button(
                onClick = { submit("/login") },
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Login")
            }
        }

        if (isLoading) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                CircularProgressIndicator()
                Text("Sending request...")
            }
        }

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("Result", style = MaterialTheme.typography.titleMedium)
                Text(resultText, style = MaterialTheme.typography.bodyMedium)
            }
        }

        Text(
            text = "Native status: $nativeStatus",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Preview(showBackground = true)
@Composable
fun BioKeyPreview() {
    BioKeyTheme {
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

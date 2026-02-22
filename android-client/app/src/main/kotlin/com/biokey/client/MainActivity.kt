package com.biokey.client

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import android.os.SystemClock
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

enum class AppScreen {
    LOGIN,
    TRAIN,
    HOME
}

@Composable
fun BioKeyScreen(nativeStatus: String) {
    val defaultBackendUrl = stringResource(id = R.string.backend_url)
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var currentScreen by rememberSaveable { mutableStateOf(AppScreen.LOGIN) }
    var serverUrl by rememberSaveable { mutableStateOf(defaultBackendUrl) }
    var userId by rememberSaveable { mutableStateOf("1") }
    var sampleText by rememberSaveable { mutableStateOf("") }
    var sampleKeyPressTimes by remember { mutableStateOf<List<Long>>(emptyList()) }
    var capturedTimings by remember { mutableStateOf<List<Timing>>(emptyList()) }
    var resultText by rememberSaveable { mutableStateOf("Ready") }
    var homeText by rememberSaveable { mutableStateOf("Welcome") }
    var isLoading by remember { mutableStateOf(false) }

    fun parseInputOrNull(): Pair<Int, List<Timing>>? {
        val parsedUserId = userId.toIntOrNull() ?: return null
        val timings = capturedTimings
        if (timings.isEmpty()) {
            return null
        }
        return parsedUserId to timings
    }

    fun doTrain() {
        val parsed = parseInputOrNull()
        if (parsed == null) {
            resultText = "Use numeric User ID and sample text with at least 2 letters/numbers"
            return
        }
        val (safeUserId, timings) = parsed
        scope.launch {
            isLoading = true
            val trainResult = ApiClient.postTimings(serverUrl, "/train", safeUserId, timings)
            resultText = "HTTP ${trainResult.statusCode}: ${trainResult.body}"
            snackbarHostState.showSnackbar("Train result: ${trainResult.statusCode}")
            isLoading = false
        }
    }

    fun doLogin() {
        val parsed = parseInputOrNull()
        if (parsed == null) {
            resultText = "Use numeric User ID and sample text with at least 2 letters/numbers"
            return
        }
        val (safeUserId, timings) = parsed
        scope.launch {
            isLoading = true
            val loginResult = ApiClient.postTimings(serverUrl, "/login", safeUserId, timings)
            val loginStatus = parseBackendStatus(loginResult.body)
            resultText = "HTTP ${loginResult.statusCode}: ${loginResult.body}"
            snackbarHostState.showSnackbar("Login: ${loginStatus ?: "UNKNOWN"}")

            if (loginStatus == "SUCCESS") {
                val trainResult = ApiClient.postTimings(serverUrl, "/train", safeUserId, timings)
                homeText = "Logged in as user $safeUserId"
                currentScreen = AppScreen.HOME
                resultText = "Login OK. Auto-train: HTTP ${trainResult.statusCode}"
                snackbarHostState.showSnackbar("Successful login counted as training")
            }

            isLoading = false
        }
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(innerPadding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            when (currentScreen) {
                AppScreen.LOGIN -> LoginScreen(
                    nativeStatus = nativeStatus,
                    serverUrl = serverUrl,
                    onServerUrlChange = { serverUrl = it.trim() },
                    userId = userId,
                    onUserIdChange = { userId = it.filter(Char::isDigit) },
                    sampleText = sampleText,
                    sampleKeyPressTimes = sampleKeyPressTimes,
                    onSampleTextChange = { updatedText, updatedKeyPressTimes ->
                        sampleText = updatedText
                        sampleKeyPressTimes = updatedKeyPressTimes
                        capturedTimings = buildTimingsFromCapturedInput(updatedText, updatedKeyPressTimes)
                    },
                    isLoading = isLoading,
                    onLogin = { doLogin() },
                    onGoTrain = { currentScreen = AppScreen.TRAIN },
                    resultText = resultText
                )

                AppScreen.TRAIN -> TrainScreen(
                    serverUrl = serverUrl,
                    onServerUrlChange = { serverUrl = it.trim() },
                    userId = userId,
                    onUserIdChange = { userId = it.filter(Char::isDigit) },
                    sampleText = sampleText,
                    sampleKeyPressTimes = sampleKeyPressTimes,
                    onSampleTextChange = { updatedText, updatedKeyPressTimes ->
                        sampleText = updatedText
                        sampleKeyPressTimes = updatedKeyPressTimes
                        capturedTimings = buildTimingsFromCapturedInput(updatedText, updatedKeyPressTimes)
                    },
                    isLoading = isLoading,
                    onTrain = { doTrain() },
                    onBack = { currentScreen = AppScreen.LOGIN },
                    resultText = resultText
                )

                AppScreen.HOME -> HomeScreen(
                    homeText = homeText,
                    onTrain = { currentScreen = AppScreen.TRAIN },
                    onLogout = { currentScreen = AppScreen.LOGIN },
                    resultText = resultText
                )
            }
        }
    }
}

@Composable
fun LoginScreen(
    nativeStatus: String,
    serverUrl: String,
    onServerUrlChange: (String) -> Unit,
    userId: String,
    onUserIdChange: (String) -> Unit,
    sampleText: String,
    sampleKeyPressTimes: List<Long>,
    onSampleTextChange: (String, List<Long>) -> Unit,
    isLoading: Boolean,
    onLogin: () -> Unit,
    onGoTrain: () -> Unit,
    resultText: String
) {
    Text("BioKey Login", style = MaterialTheme.typography.headlineMedium)
    Text(
        "Secure rhythm-based authentication",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )

    InputCard(
        serverUrl = serverUrl,
        onServerUrlChange = onServerUrlChange,
        userId = userId,
        onUserIdChange = onUserIdChange,
        sampleText = sampleText,
        sampleKeyPressTimes = sampleKeyPressTimes,
        onSampleTextChange = onSampleTextChange
    )

    Button(onClick = onLogin, enabled = !isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Login")
    }
    Button(onClick = onGoTrain, enabled = !isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Open Train Screen")
    }

    if (isLoading) {
        CircularProgressIndicator()
    }

    ResultCard(resultText = resultText)
    Text(
        text = "Native status: $nativeStatus",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
fun TrainScreen(
    serverUrl: String,
    onServerUrlChange: (String) -> Unit,
    userId: String,
    onUserIdChange: (String) -> Unit,
    sampleText: String,
    sampleKeyPressTimes: List<Long>,
    onSampleTextChange: (String, List<Long>) -> Unit,
    isLoading: Boolean,
    onTrain: () -> Unit,
    onBack: () -> Unit,
    resultText: String
) {
    Text("Training", style = MaterialTheme.typography.headlineMedium)
    Text(
        "Build your typing profile",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )

    InputCard(
        serverUrl = serverUrl,
        onServerUrlChange = onServerUrlChange,
        userId = userId,
        onUserIdChange = onUserIdChange,
        sampleText = sampleText,
        sampleKeyPressTimes = sampleKeyPressTimes,
        onSampleTextChange = onSampleTextChange
    )

    Button(onClick = onTrain, enabled = !isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Train Now")
    }
    Button(onClick = onBack, enabled = !isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Back to Login")
    }

    if (isLoading) {
        CircularProgressIndicator()
    }

    ResultCard(resultText = resultText)
}

@Composable
fun HomeScreen(
    homeText: String,
    onTrain: () -> Unit,
    onLogout: () -> Unit,
    resultText: String
) {
    Text("Home", style = MaterialTheme.typography.headlineMedium)
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(homeText, style = MaterialTheme.typography.titleMedium)
            Text("Login successful", style = MaterialTheme.typography.bodyMedium)
        }
    }

    Button(onClick = onTrain, modifier = Modifier.fillMaxWidth()) {
        Text("Go to Train Screen")
    }
    Button(onClick = onLogout, modifier = Modifier.fillMaxWidth()) {
        Text("Logout")
    }

    ResultCard(resultText = resultText)
}

@Composable
fun InputCard(
    serverUrl: String,
    onServerUrlChange: (String) -> Unit,
    userId: String,
    onUserIdChange: (String) -> Unit,
    sampleText: String,
    sampleKeyPressTimes: List<Long>,
    onSampleTextChange: (String, List<Long>) -> Unit
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            OutlinedTextField(
                value = serverUrl,
                onValueChange = onServerUrlChange,
                label = { Text("Server URL") },
                supportingText = { Text("Phone: PC Wi-Fi IP | Emulator: 10.0.2.2") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = userId,
                onValueChange = onUserIdChange,
                label = { Text("User ID") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = sampleText,
                onValueChange = { newText ->
                    val updatedPressTimes = updateKeyPressTimes(
                        previousText = sampleText,
                        nextText = newText,
                        previousPressTimes = sampleKeyPressTimes,
                        nowMillis = SystemClock.elapsedRealtime()
                    )
                    onSampleTextChange(newText, updatedPressTimes)
                },
                label = { Text("Typing Phrase") },
                supportingText = {
                    val capturedPairs = buildTimingsFromCapturedInput(sampleText, sampleKeyPressTimes).size
                    Text("Type naturally. Captured key pairs: $capturedPairs")
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
fun ResultCard(resultText: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("Result", style = MaterialTheme.typography.titleMedium)
            Text(resultText, style = MaterialTheme.typography.bodyMedium)
        }
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

data class ApiResult(
    val statusCode: Int,
    val body: String
)

fun parseBackendStatus(body: String): String? {
    return try {
        JSONObject(body).optString("status", null)
    } catch (_: Exception) {
        null
    }
}

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

fun normalizeTextForCapture(value: String): String {
    return value.lowercase().filter { it.isLetterOrDigit() }
}

fun updateKeyPressTimes(
    previousText: String,
    nextText: String,
    previousPressTimes: List<Long>,
    nowMillis: Long
): List<Long> {
    val oldNorm = normalizeTextForCapture(previousText)
    val newNorm = normalizeTextForCapture(nextText)

    if (newNorm.isEmpty()) {
        return emptyList()
    }

    var commonPrefixLength = 0
    val minLength = minOf(oldNorm.length, newNorm.length)
    while (commonPrefixLength < minLength && oldNorm[commonPrefixLength] == newNorm[commonPrefixLength]) {
        commonPrefixLength++
    }

    val updated = previousPressTimes.take(commonPrefixLength).toMutableList()
    var timeCursor = if (updated.isEmpty()) nowMillis else maxOf(nowMillis, updated.last() + 1)

    for (index in commonPrefixLength until newNorm.length) {
        updated.add(timeCursor)
        timeCursor += 1
    }

    return updated
}

fun buildTimingsFromCapturedInput(text: String, pressTimes: List<Long>): List<Timing> {
    val normalized = normalizeTextForCapture(text)
    if (normalized.length < 2 || pressTimes.size < normalized.length) {
        return emptyList()
    }

    val timings = mutableListOf<Timing>()
    for (index in 0 until normalized.length - 1) {
        val pair = "${normalized[index]}${normalized[index + 1]}"
        val rawFlight = (pressTimes[index + 1] - pressTimes[index]).toFloat()
        val flight = rawFlight.coerceIn(20f, 500f)
        val dwell = (flight * 0.65f).coerceIn(30f, 220f)
        timings.add(Timing(pair = pair, dwell = dwell, flight = flight))
    }
    return timings
}

object ApiClient {
    suspend fun postTimings(
        baseUrl: String,
        endpoint: String,
        userId: Int,
        timings: List<Timing>
    ): ApiResult = withContext(Dispatchers.IO) {
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

            ApiResult(statusCode = statusCode, body = responseBody)
        } catch (exception: Exception) {
            ApiResult(statusCode = -1, body = "Request failed: ${exception.message}")
        } finally {
            connection.disconnect()
        }
    }
}

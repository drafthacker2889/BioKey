package com.biokey.client.viewmodel

import android.app.Application
import android.content.Context
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.biokey.client.data.ApiErrorMapper
import com.biokey.client.data.BioKeyApiClient
import com.biokey.client.model.AppScreen
import com.biokey.client.model.BioKeyUiState
import com.biokey.client.model.buildTimingsFromCapturedInput
import com.biokey.client.model.parseAuthSession
import com.biokey.client.model.parseBackendStatus
import com.biokey.client.model.parseProfileSummary
import com.biokey.client.model.updateKeyPressTimes
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class BioKeyViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("biokey_prefs", Context.MODE_PRIVATE)

    private val _uiState = MutableStateFlow(
        BioKeyUiState(
            currentScreen = if (savedToken().isNotBlank()) AppScreen.HOME else AppScreen.LOGIN,
            serverUrl = defaultServerUrl(),
            userId = if (savedUserId() > 0) savedUserId().toString() else "1",
            username = savedUsername(),
            homeText = if (savedUsername().isNotBlank()) "Welcome, ${savedUsername()}" else "Welcome",
            authToken = savedToken()
        )
    )
    val uiState: StateFlow<BioKeyUiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<String>()
    val events: SharedFlow<String> = _events.asSharedFlow()

    private fun defaultServerUrl(): String {
        return "http://10.179.196.210:4567"
    }

    private fun savedToken(): String = prefs.getString("auth_token", "") ?: ""
    private fun savedUsername(): String = prefs.getString("auth_username", "") ?: ""
    private fun savedUserId(): Int = prefs.getInt("auth_user_id", -1)

    fun updateServerUrl(value: String) = _uiState.update { it.copy(serverUrl = value.trim()) }
    fun updateUserId(value: String) = _uiState.update { it.copy(userId = value.filter(Char::isDigit)) }
    fun updateUsername(value: String) = _uiState.update { it.copy(username = value) }
    fun updatePassword(value: String) = _uiState.update { it.copy(password = value) }
    fun updateScreen(screen: AppScreen) = _uiState.update { it.copy(currentScreen = screen) }

    fun onSampleTextChanged(newText: String) {
        val state = _uiState.value
        val updatedPressTimes = updateKeyPressTimes(
            previousText = state.sampleText,
            nextText = newText,
            previousPressTimes = state.sampleKeyPressTimes,
            nowMillis = SystemClock.elapsedRealtime()
        )
        val capturedTimings = buildTimingsFromCapturedInput(newText, updatedPressTimes)
        _uiState.update {
            it.copy(
                sampleText = newText,
                sampleKeyPressTimes = updatedPressTimes,
                capturedTimings = capturedTimings
            )
        }
    }

    fun doTrain() {
        val state = _uiState.value
        val parsedUserId = state.userId.toIntOrNull()
        if (parsedUserId == null || state.capturedTimings.isEmpty()) {
            _uiState.update { it.copy(resultText = "Use numeric User ID and type at least 2 letters/numbers") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val result = BioKeyApiClient.postTimings(state.serverUrl, "/train", parsedUserId, state.capturedTimings)
            _uiState.update { it.copy(resultText = "HTTP ${result.statusCode}: ${result.body}", isLoading = false) }
            _events.emit(ApiErrorMapper.toUserMessage("Train", result))
        }
    }

    fun doBiometricLogin() {
        val state = _uiState.value
        val parsedUserId = state.userId.toIntOrNull()
        if (parsedUserId == null || state.capturedTimings.isEmpty()) {
            _uiState.update { it.copy(resultText = "Use numeric User ID and type at least 2 letters/numbers") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val loginResult = BioKeyApiClient.postTimings(state.serverUrl, "/login", parsedUserId, state.capturedTimings)
            val loginStatus = parseBackendStatus(loginResult.body)
            _uiState.update { it.copy(resultText = "HTTP ${loginResult.statusCode}: ${loginResult.body}") }
            _events.emit(ApiErrorMapper.toUserMessage("Biometric login", loginResult))

            if (loginStatus == "SUCCESS") {
                val trainResult = BioKeyApiClient.postTimings(state.serverUrl, "/train", parsedUserId, state.capturedTimings)
                _uiState.update {
                    it.copy(
                        homeText = "Logged in as user $parsedUserId",
                        currentScreen = AppScreen.HOME,
                        resultText = "Login OK. Auto-train: HTTP ${trainResult.statusCode}"
                    )
                }
                _events.emit("Successful login counted as training")
            }

            _uiState.update { it.copy(isLoading = false) }
        }
    }

    fun doRegister() {
        val state = _uiState.value
        if (state.username.isBlank() || state.password.length < 6) {
            _uiState.update { it.copy(resultText = "Username required. Password must be at least 6 chars") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val result = BioKeyApiClient.postAuthCredential(
                state.serverUrl,
                "/auth/register",
                state.username.trim(),
                state.password
            )
            _uiState.update { it.copy(resultText = "HTTP ${result.statusCode}: ${result.body}", isLoading = false) }
            _events.emit(ApiErrorMapper.toUserMessage("Register", result))
        }
    }

    fun doAccountLogin() {
        val state = _uiState.value
        if (state.username.isBlank() || state.password.isBlank()) {
            _uiState.update { it.copy(resultText = "Enter username and password") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val result = BioKeyApiClient.postAuthCredential(
                state.serverUrl,
                "/auth/login",
                state.username.trim(),
                state.password
            )

            if (result.statusCode in 200..299) {
                val session = parseAuthSession(result.body)
                if (session != null) {
                    _uiState.update {
                        it.copy(
                            authToken = session.token,
                            userId = session.userId.toString(),
                            username = session.username,
                            homeText = "Welcome, ${session.username}",
                            currentScreen = AppScreen.HOME,
                            resultText = "Account login success"
                        )
                    }

                    prefs.edit()
                        .putString("auth_token", session.token)
                        .putString("auth_username", session.username)
                        .putInt("auth_user_id", session.userId)
                        .apply()

                    _events.emit(ApiErrorMapper.toUserMessage("Account login", result))
                    refreshProfile()
                } else {
                    _uiState.update { it.copy(resultText = "Auth response parse failed") }
                }
            } else {
                _uiState.update { it.copy(resultText = "HTTP ${result.statusCode}: ${result.body}") }
                _events.emit(ApiErrorMapper.toUserMessage("Account login", result))
            }

            _uiState.update { it.copy(isLoading = false) }
        }
    }

    fun refreshProfile() {
        val state = _uiState.value
        if (state.authToken.isBlank()) {
            _uiState.update { it.copy(profileText = "Not authenticated") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val result = BioKeyApiClient.getAuthProfile(state.serverUrl, state.authToken)

            if (result.statusCode == 401) {
                clearSessionState()
                _events.emit("Session expired. Please login again.")
                return@launch
            }

            val profileText = if (result.statusCode in 200..299) {
                parseProfileSummary(result.body)
            } else {
                "Profile fetch failed: HTTP ${result.statusCode}"
            }
            _uiState.update { it.copy(profileText = profileText, isLoading = false) }
        }
    }

    fun doLogout() {
        val state = _uiState.value
        viewModelScope.launch {
            if (state.authToken.isNotBlank()) {
                BioKeyApiClient.postAuthLogout(state.serverUrl, state.authToken)
            }

            clearSessionState(resultText = "Logged out")
            _events.emit("Logged out")
        }
    }

    private fun clearSessionState(resultText: String = "Session cleared") {
        prefs.edit()
            .remove("auth_token")
            .remove("auth_username")
            .remove("auth_user_id")
            .apply()

        _uiState.update {
            it.copy(
                authToken = "",
                password = "",
                profileText = "Profile not loaded",
                currentScreen = AppScreen.LOGIN,
                homeText = "Welcome",
                resultText = resultText,
                isLoading = false
            )
        }
    }
}

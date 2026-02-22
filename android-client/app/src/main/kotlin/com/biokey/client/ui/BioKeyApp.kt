package com.biokey.client.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.biokey.client.model.AppScreen
import com.biokey.client.model.BioKeyUiState
import com.biokey.client.viewmodel.BioKeyViewModel

@Composable
fun BioKeyApp(nativeStatus: String, viewModel: BioKeyViewModel) {
    val state by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        viewModel.events.collect { message ->
            snackbarHostState.showSnackbar(message)
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
            when (state.currentScreen) {
                AppScreen.LOGIN -> LoginScreen(
                    state = state,
                    nativeStatus = nativeStatus,
                    onServerUrlChange = viewModel::updateServerUrl,
                    onUserIdChange = viewModel::updateUserId,
                    onUsernameChange = viewModel::updateUsername,
                    onPasswordChange = viewModel::updatePassword,
                    onSampleTextChange = viewModel::onSampleTextChanged,
                    onAccountLogin = viewModel::doAccountLogin,
                    onRegister = viewModel::doRegister,
                    onBiometricLogin = viewModel::doBiometricLogin,
                    onGoTrain = { viewModel.updateScreen(AppScreen.TRAIN) }
                )

                AppScreen.TRAIN -> TrainScreen(
                    state = state,
                    onServerUrlChange = viewModel::updateServerUrl,
                    onUserIdChange = viewModel::updateUserId,
                    onSampleTextChange = viewModel::onSampleTextChanged,
                    onTrain = viewModel::doTrain,
                    onBack = { viewModel.updateScreen(AppScreen.LOGIN) }
                )

                AppScreen.HOME -> HomeScreen(
                    state = state,
                    onRefreshProfile = viewModel::refreshProfile,
                    onTrain = { viewModel.updateScreen(AppScreen.TRAIN) },
                    onLogout = viewModel::doLogout
                )
            }
        }
    }
}

@Composable
private fun LoginScreen(
    state: BioKeyUiState,
    nativeStatus: String,
    onServerUrlChange: (String) -> Unit,
    onUserIdChange: (String) -> Unit,
    onUsernameChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onSampleTextChange: (String) -> Unit,
    onAccountLogin: () -> Unit,
    onRegister: () -> Unit,
    onBiometricLogin: () -> Unit,
    onGoTrain: () -> Unit
) {
    Text("BioKey Login", style = MaterialTheme.typography.headlineMedium)
    Text(
        "Secure rhythm-based authentication",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Account", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = state.username,
                onValueChange = onUsernameChange,
                label = { Text("Username") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = state.password,
                onValueChange = onPasswordChange,
                label = { Text("Password") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(onClick = onAccountLogin, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
                Text("Account Login")
            }
            Button(onClick = onRegister, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
                Text("Register")
            }
        }
    }

    InputCard(
        state = state,
        onServerUrlChange = onServerUrlChange,
        onUserIdChange = onUserIdChange,
        onSampleTextChange = onSampleTextChange
    )

    Button(onClick = onBiometricLogin, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Biometric Login")
    }
    Button(onClick = onGoTrain, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Open Train Screen")
    }

    if (state.isLoading) CircularProgressIndicator()

    ResultCard(state.resultText)
    Text(
        text = "Native status: $nativeStatus",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun TrainScreen(
    state: BioKeyUiState,
    onServerUrlChange: (String) -> Unit,
    onUserIdChange: (String) -> Unit,
    onSampleTextChange: (String) -> Unit,
    onTrain: () -> Unit,
    onBack: () -> Unit
) {
    Text("Training", style = MaterialTheme.typography.headlineMedium)
    Text(
        "Build your typing profile",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )

    InputCard(
        state = state,
        onServerUrlChange = onServerUrlChange,
        onUserIdChange = onUserIdChange,
        onSampleTextChange = onSampleTextChange
    )

    Button(onClick = onTrain, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Train Now")
    }
    Button(onClick = onBack, enabled = !state.isLoading, modifier = Modifier.fillMaxWidth()) {
        Text("Back to Login")
    }

    if (state.isLoading) CircularProgressIndicator()

    ResultCard(state.resultText)
}

@Composable
private fun HomeScreen(
    state: BioKeyUiState,
    onRefreshProfile: () -> Unit,
    onTrain: () -> Unit,
    onLogout: () -> Unit
) {
    Text("Home", style = MaterialTheme.typography.headlineMedium)
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(state.homeText, style = MaterialTheme.typography.titleMedium)
            Text("Login successful", style = MaterialTheme.typography.bodyMedium)
            Text(state.profileText, style = MaterialTheme.typography.bodyMedium)
        }
    }

    Button(onClick = onRefreshProfile, modifier = Modifier.fillMaxWidth()) {
        Text("Refresh Profile")
    }
    Button(onClick = onTrain, modifier = Modifier.fillMaxWidth()) {
        Text("Go to Train Screen")
    }
    Button(onClick = onLogout, modifier = Modifier.fillMaxWidth()) {
        Text("Logout")
    }

    ResultCard(state.resultText)
}

@Composable
private fun InputCard(
    state: BioKeyUiState,
    onServerUrlChange: (String) -> Unit,
    onUserIdChange: (String) -> Unit,
    onSampleTextChange: (String) -> Unit
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = state.serverUrl,
                onValueChange = onServerUrlChange,
                label = { Text("Server URL") },
                supportingText = { Text("Phone: PC Wi-Fi IP | Emulator: 10.0.2.2") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = state.userId,
                onValueChange = onUserIdChange,
                label = { Text("User ID") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = state.sampleText,
                onValueChange = onSampleTextChange,
                label = { Text("Typing Phrase") },
                supportingText = { Text("Type naturally. Captured key pairs: ${state.capturedTimings.size}") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun ResultCard(resultText: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Result", style = MaterialTheme.typography.titleMedium)
            Text(resultText, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

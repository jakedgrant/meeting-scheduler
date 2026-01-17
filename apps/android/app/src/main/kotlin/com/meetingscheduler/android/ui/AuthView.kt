package com.meetingscheduler.android.ui

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Language
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import com.meetingscheduler.android.services.AuthService
import kotlinx.coroutines.launch
import java.security.MessageDigest
import java.util.UUID

private const val TAG = "AuthView"
private const val WEB_CLIENT_ID = "761708589972-t4o5c3b51shbt84h6ijpsr1qom0ri54s.apps.googleusercontent.com"

@Composable
fun AuthView(authService: AuthService) {
    var email by remember { mutableStateOf(TextFieldValue("")) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var showMagicLinkSent by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val credentialManager = remember { CredentialManager.create(context) }

    // Generate a raw nonce for security (prevents replay attacks)
    // Returns a pair of (rawNonce, hashedNonce)
    // - rawNonce: passed to Supabase for verification
    // - hashedNonce: passed to Google Credential Manager
    fun generateNonce(): Pair<String, String> {
        val rawNonce = UUID.randomUUID().toString()
        val bytes = rawNonce.toByteArray()
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(bytes)
        val hashedNonce = digest.fold("") { str, it -> str + "%02x".format(it) }
        return Pair(rawNonce, hashedNonce)
    }

    // Handle the credential response from Google Sign-In
    // Note: rawNonce is the unhashed nonce that Supabase needs for verification
    suspend fun handleSignIn(result: GetCredentialResponse, rawNonce: String) {
        when (val credential = result.credential) {
            is CustomCredential -> {
                if (credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                    try {
                        val googleIdTokenCredential = GoogleIdTokenCredential.createFrom(credential.data)
                        val idToken = googleIdTokenCredential.idToken
                        Log.d(TAG, "Successfully received Google ID token, signing in with Supabase...")
                        authService.signInWithGoogle(idToken, rawNonce)
                        Log.d(TAG, "Supabase sign-in completed successfully")
                    } catch (e: GoogleIdTokenParsingException) {
                        Log.e(TAG, "Received an invalid Google ID token response", e)
                        errorMessage = "Failed to parse Google credentials"
                    } catch (e: Exception) {
                        Log.e(TAG, "Supabase sign-in failed: ${e.message}", e)
                        errorMessage = e.message ?: "Sign-in failed"
                    }
                } else {
                    Log.e(TAG, "Unexpected credential type: ${credential.type}")
                    errorMessage = "Unexpected credential type"
                }
            }
            else -> {
                Log.e(TAG, "Unexpected credential class: ${credential::class.java}")
                errorMessage = "Unexpected credential type"
            }
        }
    }

    // Sign in with Google using Credential Manager
    fun signInWithGoogle() {
        isLoading = true
        errorMessage = null
        val (rawNonce, hashedNonce) = generateNonce()

        scope.launch {
            try {
                // First, try One Tap sign-in for returning users (faster UX)
                val googleIdOption = GetGoogleIdOption.Builder()
                    .setFilterByAuthorizedAccounts(true)
                    .setServerClientId(WEB_CLIENT_ID)
                    .setAutoSelectEnabled(true)
                    .setNonce(hashedNonce)
                    .build()

                val oneTapRequest = GetCredentialRequest.Builder()
                    .addCredentialOption(googleIdOption)
                    .build()

                try {
                    val result = credentialManager.getCredential(context, oneTapRequest)
                    handleSignIn(result, rawNonce)
                    return@launch
                } catch (e: NoCredentialException) {
                    Log.d(TAG, "No returning user, using Sign In With Google button flow")
                } catch (e: GetCredentialCancellationException) {
                    // User cancelled One Tap or it failed after account selection, fall through to SIWG
                    Log.d(TAG, "One Tap cancelled or failed, falling back to Sign In With Google: ${e.message}")
                } catch (e: GetCredentialException) {
                    Log.d(TAG, "One Tap failed, falling back to Sign In With Google: ${e.type} - ${e.message}")
                }

                // Fall back to "Sign In With Google" button flow
                // This works without Android OAuth client, only needs Web Client ID
                val signInWithGoogleOption = GetSignInWithGoogleOption.Builder(WEB_CLIENT_ID)
                    .setNonce(hashedNonce)
                    .build()

                val signInRequest = GetCredentialRequest.Builder()
                    .addCredentialOption(signInWithGoogleOption)
                    .build()

                val result = credentialManager.getCredential(context, signInRequest)
                handleSignIn(result, rawNonce)

            } catch (e: GetCredentialCancellationException) {
                Log.d(TAG, "User cancelled Google sign-in: ${e.message}")
                // User cancelled, no error message needed
            } catch (e: GetCredentialException) {
                Log.e(TAG, "Google sign-in failed: ${e.type} - ${e.message}", e)
                errorMessage = "Google sign-in failed. Please ensure you have a Google account on this device."
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error during Google sign-in: ${e.javaClass.simpleName}", e)
                errorMessage = e.message ?: "Sign-in failed"
            } finally {
                isLoading = false
            }
        }
    }

    fun signInWithMagicLink() {
        if (email.text.isBlank()) {
            errorMessage = "Please enter your email"
            return
        }

        isLoading = true
        errorMessage = null
        scope.launch {
            try {
                authService.signInWithMagicLink(email.text)
                showMagicLinkSent = true
            } catch (e: Exception) {
                errorMessage = e.message
            } finally {
                isLoading = false
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            Spacer(modifier = Modifier.weight(1f))

            // Logo Section
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Language,
                    contentDescription = null,
                    modifier = Modifier.size(60.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = "Meeting Scheduler",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = "Find the perfect meeting time",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            // OAuth Buttons
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Button(
                    onClick = { signInWithGoogle() },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = !isLoading,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    ),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Icon(Icons.Default.Language, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Continue with Google")
                }
            }

            // Divider
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Divider(modifier = Modifier.weight(1f))
                Text("or", style = MaterialTheme.typography.bodySmall)
                Divider(modifier = Modifier.weight(1f))
            }

            // Magic Link Section
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("Email") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading,
                    singleLine = true
                )

                Button(
                    onClick = { signInWithMagicLink() },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = !isLoading,
                    shape = RoundedCornerShape(10.dp)
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    } else {
                        Text("Send Magic Link")
                    }
                }
            }

            // Error Message
            errorMessage?.let { error ->
                Text(
                    text = error,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall
                )
            }

            Spacer(modifier = Modifier.weight(1f))
        }
    }

    // Magic Link Sent Dialog
    if (showMagicLinkSent) {
        AlertDialog(
            onDismissRequest = { showMagicLinkSent = false },
            title = { Text("Check your email") },
            text = { Text("We've sent a sign-in link to ${email.text}") },
            confirmButton = {
                TextButton(onClick = { showMagicLinkSent = false }) {
                    Text("OK")
                }
            }
        )
    }
}

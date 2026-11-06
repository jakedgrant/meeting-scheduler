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
import android.content.Context
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import com.meetingscheduler.android.services.SignInAuth
import kotlinx.coroutines.Job

private const val TAG = "AuthView"
private const val WEB_CLIENT_ID = "761708589972-t4o5c3b51shbt84h6ijpsr1qom0ri54s.apps.googleusercontent.com"

/**
 * Asks the system credential UI for a Google ID token. [context] must be the Activity, which the
 * UI needs; the source lives only as long as one sign-in, which [AuthView] cancels when it leaves
 * the composition.
 */
private fun googleCredentialSource(context: Context, credentialManager: CredentialManager) =
    GoogleCredentialSource { hashedNonce, returningAccountsOnly ->
        val option = if (returningAccountsOnly) {
            // One Tap for returning users is faster.
            GetGoogleIdOption.Builder()
                .setFilterByAuthorizedAccounts(true)
                .setServerClientId(WEB_CLIENT_ID)
                .setAutoSelectEnabled(true)
                .setNonce(hashedNonce)
                .build()
        } else {
            // Works without an Android OAuth client; only needs the Web Client ID.
            GetSignInWithGoogleOption.Builder(WEB_CLIENT_ID).setNonce(hashedNonce).build()
        }
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val response = try {
            credentialManager.getCredential(context, request)
        } catch (e: GetCredentialCancellationException) {
            Log.d(TAG, "Google sign-in cancelled")
            throw GoogleCredentialCancelled()
        } catch (e: NoCredentialException) {
            Log.d(TAG, "No returning user")
            throw GoogleCredentialUnavailable()
        } catch (e: GetCredentialException) {
            Log.d(TAG, "Google credential request failed: ${e.type}")
            throw GoogleCredentialFailed(e)
        }
        val credential = response.credential
        if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
            throw GoogleCredentialRejected("Unexpected credential type")
        }
        try {
            GoogleIdTokenCredential.createFrom(credential.data).idToken
        } catch (e: GoogleIdTokenParsingException) {
            throw GoogleCredentialRejected("Failed to parse Google credentials", e)
        }
    }

@Composable
fun AuthView(authService: SignInAuth) {
    // The holder is kept by the store of this identity generation (see ContentView), so the form
    // and a magic-link request outlast the Activity; the next generation gets a fresh form.
    val holder = signInHolder(authService)
    val model = holder.opened.getOrThrow()
    val context = LocalContext.current
    val credentialManager = remember { CredentialManager.create(context) }

    // The credential UI belongs to this Activity, so a Google sign-in does not outlive its composition.
    var googleSignIn by remember { mutableStateOf<Job?>(null) }
    DisposableEffect(holder) { onDispose { googleSignIn?.cancel() } }

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
                    onClick = {
                        googleSignIn = holder.launch { signInWithGoogle(googleCredentialSource(context, credentialManager)) }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = !model.isLoading,
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

            TextButton(onClick = { holder.launch { signInWithGoogleBrowser() } }, enabled = !model.isLoading) { Text("Sign in with Google in browser") }

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
                    value = model.email,
                    onValueChange = model::editEmail,
                    label = { Text("Email") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !model.isLoading,
                    singleLine = true
                )

                Button(
                    onClick = { holder.launch { signInWithMagicLink() } },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = !model.isLoading,
                    shape = RoundedCornerShape(10.dp)
                ) {
                    if (model.isLoading) {
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
            model.displayedError?.let { error ->
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
    if (model.showMagicLinkSent) {
        AlertDialog(
            onDismissRequest = model::dismissMagicLinkSent,
            title = { Text("Check your email") },
            text = { Text("We've sent a sign-in link to ${model.email}") },
            confirmButton = {
                TextButton(onClick = model::dismissMagicLinkSent) {
                    Text("OK")
                }
            }
        )
    }
}

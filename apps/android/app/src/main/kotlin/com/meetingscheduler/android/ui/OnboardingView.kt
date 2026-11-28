package com.meetingscheduler.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.meetingscheduler.android.models.DisplayNameInput
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import kotlinx.coroutines.launch

/** Meetful's orange, #F7931E. */
val BrandOrange = Color(0xFFF7931E)

private const val STEP_COUNT = 2

/**
 * The two optional steps after an account's first sign-in: a display name, then Google Calendar.
 * Skip on the name step moves on; Finish or Skip on the calendar step completes onboarding.
 * System back on the calendar step returns to the name step.
 */
@Composable
fun OnboardingView(authService: AuthService, calendarService: CalendarService) {
    var step by rememberSaveable { mutableIntStateOf(1) }
    BackHandler(enabled = step == 2) { step = 1 }
    AnimatedContent(
        targetState = step,
        transitionSpec = {
            val forward = targetState > initialState
            slideInHorizontally { if (forward) it else -it } togetherWith slideOutHorizontally { if (forward) -it else it }
        },
        label = "onboarding step",
    ) { current ->
        when (current) {
            1 -> OnboardingNameStep(
                authService = authService,
                onContinue = { name ->
                    authService.saveOnboardingName(name)
                    step = 2
                },
                onSkip = { step = 2 },
            )
            else -> OnboardingCalendarStep(calendarService = calendarService, onFinish = authService::completeOnboarding)
        }
    }
}

/** The chrome both steps share: header, progress, serif title and subtitle, and the pinned button. */
@Composable
private fun OnboardingStepLayout(
    step: Int,
    title: String,
    subtitle: String,
    primaryTitle: String,
    onPrimary: () -> Unit,
    onSkip: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val dark = isSystemInDarkTheme()
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .systemBarsPadding()
            .imePadding()
    ) {
        Column(Modifier.padding(horizontal = 24.dp).padding(top = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Step $step of $STEP_COUNT",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onSkip) {
                    Text("Skip", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(top = 4.dp).clearAndSetSemantics {},
            ) {
                for (segment in 1..STEP_COUNT) {
                    Box(
                        Modifier
                            .weight(1f)
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(if (segment <= step) BrandOrange else MaterialTheme.colorScheme.surfaceVariant)
                    )
                }
            }
        }
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(top = 32.dp, bottom = 24.dp)
        ) {
            Text(
                title,
                style = TextStyle(fontFamily = FontFamily.Serif, fontSize = 30.sp, lineHeight = 38.sp),
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
            Spacer(Modifier.height(28.dp))
            content()
        }
        Button(
            onClick = onPrimary,
            shape = CircleShape,
            colors = ButtonDefaults.buttonColors(
                containerColor = if (dark) Color.White else Color.Black,
                contentColor = if (dark) Color.Black else Color.White,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 8.dp)
                .heightIn(min = 54.dp),
        ) {
            Text(primaryTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun OnboardingNameStep(authService: AuthService, onContinue: (String) -> Unit, onSkip: () -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    // Once the person types, a name arriving later from sign-in no longer replaces theirs.
    var edited by rememberSaveable { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val providerName = authService.profile?.displayName
    LaunchedEffect(providerName) { if (!edited) name = providerName ?: "" }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    OnboardingStepLayout(
        step = 1,
        title = "What should people call you?",
        subtitle = "Your name shows next to your answers in polls. Leave it blank to appear as Anonymous.",
        primaryTitle = "Continue",
        onPrimary = { onContinue(name) },
        onSkip = onSkip,
    ) {
        BasicTextField(
            value = name,
            onValueChange = {
                name = DisplayNameInput.limited(it)
                edited = true
            },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = SolidColor(BrandOrange),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.Words,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Next,
            ),
            keyboardActions = KeyboardActions(onNext = { onContinue(name) }),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focusRequester)
                .onFocusChanged { focused = it.isFocused }
                .semantics { contentDescription = "Your name" },
            decorationBox = { field ->
                Box(
                    contentAlignment = Alignment.CenterStart,
                    modifier = Modifier
                        .heightIn(min = 52.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surface)
                        .border(
                            width = if (focused) 1.5.dp else 1.dp,
                            color = if (focused) BrandOrange else MaterialTheme.colorScheme.outlineVariant,
                            shape = CircleShape,
                        )
                        .padding(horizontal = 22.dp),
                ) {
                    if (name.isEmpty()) {
                        Text("Your name", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    field()
                }
            },
        )
        Text(
            "How others will see you",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 10.dp, top = 34.dp),
        )
        ResponsePreview(
            name = DisplayNameInput.stored(name),
            avatarUrl = authService.profile?.avatarUrl,
            modifier = Modifier.padding(top = 10.dp),
        )
    }
}

/** A poll response row showing [name] answering yes, or "Anonymous" when there is no name. */
@Composable
private fun ResponsePreview(name: String?, avatarUrl: String?, modifier: Modifier = Modifier) {
    val shown = name ?: "Anonymous"
    val dark = isSystemInDarkTheme()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp)
            .clearAndSetSemantics { contentDescription = "Preview: $shown, answered yes" },
    ) {
        val avatarModifier = Modifier.size(36.dp).clip(CircleShape)
        if (avatarUrl != null) {
            AsyncImage(model = avatarUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = avatarModifier)
        } else {
            Box(
                contentAlignment = Alignment.Center,
                modifier = avatarModifier.background(
                    if (name == null) MaterialTheme.colorScheme.surfaceVariant else BrandOrange.copy(alpha = 0.15f)
                ),
            ) {
                Text(
                    if (name == null) "?" else shown.take(1).uppercase(),
                    fontWeight = FontWeight.SemiBold,
                    color = when {
                        name == null -> MaterialTheme.colorScheme.onSurfaceVariant
                        dark -> BrandOrange
                        else -> Color(0xFFB25E06)
                    },
                )
            }
        }
        Text(
            shown,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            modifier = Modifier.weight(1f).padding(start = 14.dp, end = 8.dp),
        )
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(width = 44.dp, height = 34.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(0xFF34C759).copy(alpha = 0.15f)),
        ) {
            Icon(Icons.Default.Check, contentDescription = null, tint = Color(0xFF34C759))
        }
    }
}

/**
 * Step 2: connect Google Calendar so poll times can show conflicts. It reads and changes the
 * same state as the Calendar Integration section in Settings. The device calendar stays in
 * Settings on Android.
 */
@Composable
private fun OnboardingCalendarStep(calendarService: CalendarService, onFinish: () -> Unit) {
    val scope = rememberCoroutineScope()
    // A calendar error counts as this screen's failure only after its own Connect.
    var attempted by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { calendarService.refreshGoogleCalendarConnection() }
    val connected = calendarService.googleCalendarEnabled
    val connecting = !connected && calendarService.googleCalendarLoading
    val failed = !connected && !connecting && attempted && calendarService.calendarError != null
    val connect = {
        attempted = true
        scope.launch { calendarService.setGoogleCalendarEnabled(true) }
        Unit
    }
    val subtitle = "Read-only. We only see busy or free, never event details."

    OnboardingStepLayout(
        step = 2,
        title = "Spot conflicts before you answer",
        subtitle = "Connect a calendar and we'll flag poll times when you're already busy.",
        primaryTitle = "Finish",
        onPrimary = onFinish,
        onSkip = onFinish,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(16.dp)
                .clearAndSetSemantics {
                    contentDescription = "Google Calendar, $subtitle" + if (failed) ". Couldn't connect. Try again." else ""
                    stateDescription = when {
                        connected -> "Connected"
                        connecting -> "Connecting"
                        else -> "Not connected"
                    }
                    if (!connected && !connecting) {
                        role = Role.Button
                        onClick(label = "Connect") { connect(); true }
                    }
                },
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(28.dp).border(2.dp, Color(0xFFEA4335), CircleShape),
            ) {
                Text("G", color = Color(0xFFEA4335), fontWeight = FontWeight.Bold, fontSize = 14.sp)
            }
            Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                Text("Google Calendar", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (failed) {
                    Text("Couldn't connect. Try again.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
            when {
                connected -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color(0xFF34C759).copy(alpha = 0.15f))
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    val green = if (isSystemInDarkTheme()) Color(0xFF73D980) else Color(0xFF1A8033)
                    Icon(Icons.Default.Check, contentDescription = null, tint = green, modifier = Modifier.size(18.dp))
                    Text("Connected", color = green, modifier = Modifier.padding(start = 6.dp))
                }
                connecting -> CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                else -> OutlinedButton(onClick = connect, shape = CircleShape) { Text("Connect") }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = 12.dp, top = 14.dp),
        ) {
            Icon(
                Icons.Default.Lock,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
            Text(
                "You can change this anytime in Settings.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
    }
}

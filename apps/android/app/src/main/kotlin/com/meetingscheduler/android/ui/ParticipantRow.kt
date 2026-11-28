package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.R
import com.meetingscheduler.android.models.PollParticipant
import java.text.DateFormat
import java.util.Date

@Composable
fun ParticipantsHeading(participants: List<PollParticipant>) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.participants_heading, participants.size), style = MaterialTheme.typography.titleMedium)
        Text(
            stringResource(R.string.participant_submission_count, participants.count { it.submittedAt != null }, participants.size),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
fun ParticipantRow(participant: PollParticipant, isCurrentUser: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(participant.displayName, modifier = Modifier.weight(1f, fill = false))
            if (isCurrentUser) {
                Spacer(Modifier.width(8.dp))
                Surface(color = MaterialTheme.colorScheme.primary, shape = RoundedCornerShape(12.dp)) {
                    Text(
                        "You",
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                }
            }
        }
        Text(
            participant.submittedAt?.let {
                val formatted = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                    .format(Date(it.toEpochMilliseconds()))
                stringResource(R.string.participant_submitted_at, formatted)
            } ?: stringResource(R.string.participant_not_submitted),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        participant.comment?.takeIf { it.isNotBlank() }?.let { comment ->
            Text(
                comment,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontStyle = FontStyle.Italic
            )
        }
    }
}

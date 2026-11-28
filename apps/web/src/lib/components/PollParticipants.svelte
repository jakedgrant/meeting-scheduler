<script lang="ts">
	import type { PollParticipant } from '../supabase';

	let { participants, currentParticipantId }: {
		participants: PollParticipant[];
		currentParticipantId?: string;
	} = $props();
	const submittedCount = $derived(participants.filter(participant => participant.submitted_at != null).length);
</script>

<div class="participants-section">
	<h2>Participants ({participants.length})</h2>
	<p class="submission-count">{submittedCount} of {participants.length} submitted</p>
	{#if participants.length === 0}
		<p class="no-participants">No participants yet</p>
	{:else}
		<ul class="participants-list">
			{#each participants as participant}
				<li>
					<div class="participant-info">
						<div class="participant-header">
							<span class="participant-name">
								{participant.profiles?.display_name || participant.anonymous_name || 'Anonymous'}
							</span>
							{#if participant.id === currentParticipantId}
								<span class="you-badge">You</span>
							{/if}
						</div>
						<p class="submission-status">
							{#if participant.submitted_at}
								Submitted <time datetime={participant.submitted_at}>{new Date(participant.submitted_at).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}</time>
							{:else}
								Not submitted
							{/if}
						</p>
						{#if participant.comment}
							<p class="participant-comment">{participant.comment}</p>
						{/if}
					</div>
				</li>
			{/each}
		</ul>
	{/if}
</div>

<style>
	.participants-section {
		background: white;
		border-radius: 8px;
		padding: 1.5rem;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
	}
	h2 { margin: 0 0 0.5rem; font-size: 1.125rem; }
	.submission-count { margin: 0 0 1rem; color: #666; font-size: 0.875rem; }
	.submission-status { margin: 0; color: #666; font-size: 0.8125rem; }
	.participants-list {
		list-style: none;
		padding: 0;
		margin: 0;
	}

	.participants-list li {
		padding: 0.75rem 0;
		border-bottom: 1px solid #eee;
	}

	.participants-list li:last-child {
		border-bottom: none;
	}

	.participant-info {
		min-width: 0;
		overflow-wrap: anywhere;
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.participant-header {
		flex-wrap: wrap;
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}

	.participant-comment {
		font-size: 0.8125rem;
		color: #666;
		font-style: italic;
		margin: 0;
		padding-left: 0;
	}

	.you-badge {
		background: #007bff;
		color: white;
		padding: 0.125rem 0.375rem;
		border-radius: 4px;
		font-size: 0.75rem;
	}

	.no-participants {
		color: #666;
		font-size: 0.875rem;
	}
</style>

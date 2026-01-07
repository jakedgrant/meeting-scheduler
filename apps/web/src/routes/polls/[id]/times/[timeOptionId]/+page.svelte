<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import {
		currentPoll,
		currentPollTimeOptions,
		currentPollParticipants,
		currentPollResponses,
		loadPoll,
		cleanupPollRealtime
	} from '$lib/stores/polls';
	import type { AvailabilityStatus } from '$lib/supabase';

	const pollId = $derived($page.params.id as string);
	const timeOptionId = $derived($page.params.timeOptionId as string);

	const timeOption = $derived(
		$currentPollTimeOptions.find((opt) => opt.id === timeOptionId)
	);

	interface ResponseWithParticipant {
		id: string;
		participant_id: string;
		status: AvailabilityStatus;
		note: string | null;
		participant_name: string;
	}

	const responsesForOption = $derived.by(() => {
		const responses = $currentPollResponses.filter((r) => r.time_option_id === timeOptionId);

		// Map responses to include participant names
		const responsesWithParticipants: ResponseWithParticipant[] = responses.map((response) => {
			const participant = $currentPollParticipants.find((p) => p.id === response.participant_id);
			const participantName =
				participant?.profiles?.display_name || participant?.anonymous_name || 'Anonymous';

			return {
				id: response.id,
				participant_id: response.participant_id,
				status: response.status,
				note: response.note,
				participant_name: participantName
			};
		});

		// Sort by status: available, maybe, unavailable
		const statusOrder: Record<AvailabilityStatus, number> = {
			available: 1,
			maybe: 2,
			unavailable: 3
		};

		return responsesWithParticipants.sort((a, b) => {
			const orderDiff = statusOrder[a.status] - statusOrder[b.status];
			if (orderDiff !== 0) return orderDiff;
			// If same status, sort alphabetically by name
			return a.participant_name.localeCompare(b.participant_name);
		});
	});

	const groupedResponses = $derived.by(() => {
		return {
			available: responsesForOption.filter((r) => r.status === 'available'),
			maybe: responsesForOption.filter((r) => r.status === 'maybe'),
			unavailable: responsesForOption.filter((r) => r.status === 'unavailable')
		};
	});

	onMount(() => {
		if (pollId) loadPoll(pollId);
	});

	onDestroy(() => {
		cleanupPollRealtime();
	});

	function formatDateTime(isoString: string) {
		const date = new Date(isoString);
		return {
			date: date.toLocaleDateString('en-US', {
				weekday: 'long',
				month: 'long',
				day: 'numeric',
				year: 'numeric'
			}),
			time: date.toLocaleTimeString('en-US', {
				hour: 'numeric',
				minute: '2-digit'
			})
		};
	}

	function goBack() {
		goto(`/polls/${pollId}`);
	}
</script>

<div class="responses-detail">
	{#if !timeOption}
		<div class="loading">Loading...</div>
	{:else}
		{@const formatted = formatDateTime(timeOption.start_time)}
		{@const endFormatted = formatDateTime(timeOption.end_time)}
		<header>
			<button class="back-link" onclick={goBack}>&larr; Back to Poll</button>
			<h1>Responses for Time Option</h1>
			<div class="time-option-info">
				<div class="date">{formatted.date}</div>
				<div class="time">
					{#if timeOption.is_all_day}
						All day
					{:else}
						{formatted.time} - {endFormatted.time}
					{/if}
				</div>
			</div>
		</header>

		<div class="responses-container">
			{#if responsesForOption.length === 0}
				<div class="no-responses">No responses yet for this time option</div>
			{:else}
				<!-- Available -->
				{#if groupedResponses.available.length > 0}
					<div class="response-group">
						<h2 class="group-header available">
							<span class="status-icon">✓</span>
							Available ({groupedResponses.available.length})
						</h2>
						<ul class="response-list">
							{#each groupedResponses.available as response}
								<li class="response-item available">
									<span class="participant-name">{response.participant_name}</span>
									{#if response.note}
										<span class="note">{response.note}</span>
									{/if}
								</li>
							{/each}
						</ul>
					</div>
				{/if}

				<!-- Maybe -->
				{#if groupedResponses.maybe.length > 0}
					<div class="response-group">
						<h2 class="group-header maybe">
							<span class="status-icon">?</span>
							Tentative ({groupedResponses.maybe.length})
						</h2>
						<ul class="response-list">
							{#each groupedResponses.maybe as response}
								<li class="response-item maybe">
									<span class="participant-name">{response.participant_name}</span>
									{#if response.note}
										<span class="note">{response.note}</span>
									{/if}
								</li>
							{/each}
						</ul>
					</div>
				{/if}

				<!-- Unavailable -->
				{#if groupedResponses.unavailable.length > 0}
					<div class="response-group">
						<h2 class="group-header unavailable">
							<span class="status-icon">✗</span>
							Not Available ({groupedResponses.unavailable.length})
						</h2>
						<ul class="response-list">
							{#each groupedResponses.unavailable as response}
								<li class="response-item unavailable">
									<span class="participant-name">{response.participant_name}</span>
									{#if response.note}
										<span class="note">{response.note}</span>
									{/if}
								</li>
							{/each}
						</ul>
					</div>
				{/if}
			{/if}
		</div>
	{/if}
</div>

<style>
	.responses-detail {
		max-width: 600px;
		margin: 0 auto;
		padding: 2rem;
	}

	.loading {
		text-align: center;
		padding: 4rem;
	}

	.back-link {
		background: none;
		border: none;
		color: #666;
		text-decoration: none;
		font-size: 0.875rem;
		cursor: pointer;
		padding: 0;
		display: inline-block;
		margin-bottom: 1rem;
	}

	.back-link:hover {
		color: #333;
	}

	header h1 {
		margin: 0 0 1rem;
		font-size: 1.5rem;
	}

	.time-option-info {
		background: #f8f9fa;
		padding: 1rem;
		border-radius: 8px;
		margin-bottom: 2rem;
	}

	.time-option-info .date {
		font-weight: 500;
		font-size: 1.125rem;
		margin-bottom: 0.25rem;
	}

	.time-option-info .time {
		color: #666;
		font-size: 1rem;
	}

	.responses-container {
		display: flex;
		flex-direction: column;
		gap: 1.5rem;
	}

	.no-responses {
		text-align: center;
		padding: 3rem;
		color: #666;
		background: #f8f9fa;
		border-radius: 8px;
	}

	.response-group {
		background: white;
		border-radius: 8px;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
		overflow: hidden;
	}

	.group-header {
		margin: 0;
		padding: 1rem 1.25rem;
		font-size: 1rem;
		font-weight: 600;
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}

	.group-header.available {
		background: #d4edda;
		color: #155724;
	}

	.group-header.maybe {
		background: #fff3cd;
		color: #856404;
	}

	.group-header.unavailable {
		background: #f8d7da;
		color: #721c24;
	}

	.status-icon {
		font-size: 1.125rem;
	}

	.response-list {
		list-style: none;
		padding: 0;
		margin: 0;
	}

	.response-item {
		padding: 0.875rem 1.25rem;
		border-bottom: 1px solid #eee;
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.response-item:last-child {
		border-bottom: none;
	}

	.participant-name {
		font-weight: 500;
	}

	.note {
		font-size: 0.875rem;
		color: #666;
		font-style: italic;
	}
</style>

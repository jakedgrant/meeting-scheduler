<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { user, profile } from '$lib/stores/auth';
	import {
		currentPoll,
		currentPollTimeOptions,
		currentPollParticipants,
		currentPollResponses,
		currentGuest,
		guestNotice,
		pollsLoading,
		loadPoll,
		cleanupPollRealtime,
		updatePollStatus,
		setSelectedFinalDate,
		joinPoll,
		submitAvailability,
		updateParticipantComment
	} from '$lib/stores/polls';
	import { calendarEnabled, calendarConflicts, calendarStatusError, checkCalendarConflicts } from '$lib/stores/calendar';
	import type { AvailabilityStatus } from '$lib/supabase';
	import { generateICS, downloadICS, generateGoogleCalendarUrl } from '$lib/calendar-utils';

	const pollId = $derived($page.params.id as string);

	let isCreator = $derived($currentPoll?.creator_id === $user?.id);
	// Signed-out guests are identified by the participant id stored with their capability.
	let isGuest = $derived(!$user && !!$currentGuest);
	let myParticipant = $derived(
		$user
			? $currentPollParticipants.find((p) => p.user_id === $user?.id)
			: $currentPollParticipants.find((p) => p.id === $currentGuest?.participantId)
	);

	// For anonymous users joining
	let anonymousName = $state('');
	let joiningPoll = $state(false);
	let joinError = $state('');

	// Track local response changes before saving
	let localResponses = $state<Record<string, AvailabilityStatus>>({});
	let localComment = $state('');
	let commentError = $state('');
	let savingResponses = $state(false);

	const MAX_COMMENT_LENGTH = 500;

	// Copy button states
	let codeCopied = $state(false);
	let linkCopied = $state(false);

	// Final date selection
	let selectingFinalDate = $state(false);

	// Add to calendar dropdown
	let showCalendarDropdown = $state(false);

	// Sort time options by availability (# available, then # maybe)
	let sortedTimeOptions = $derived(
		[...$currentPollTimeOptions].sort((a, b) => {
			const statsA = getResponsesForTimeOption(a.id);
			const statsB = getResponsesForTimeOption(b.id);

			// First, sort by available count (descending)
			if (statsB.available !== statsA.available) {
				return statsB.available - statsA.available;
			}

			// If available counts are equal, sort by maybe count (descending)
			return statsB.maybe - statsA.maybe;
		})
	);

	onMount(() => {
		if (pollId) loadPoll(pollId);
	});

	onDestroy(() => {
		cleanupPollRealtime();
	});

	// Initialize local responses and comment when participant data loads
	$effect(() => {
		if (myParticipant && $currentPollResponses.length > 0) {
			const myResponses = $currentPollResponses.filter(
				(r) => r.participant_id === myParticipant?.id
			);
			const responseMap: Record<string, AvailabilityStatus> = {};
			myResponses.forEach((r) => {
				responseMap[r.time_option_id] = r.status;
			});
			localResponses = responseMap;
		}
	});

	// Initialize comment when participant loads
	$effect(() => {
		if (myParticipant) {
			localComment = myParticipant.comment || '';
		}
	});

	// Check for calendar conflicts when poll loads and calendar is enabled
	$effect(() => {
		if ($calendarEnabled && $currentPollTimeOptions.length > 0) {
			(async () => {
				await checkCalendarConflicts($currentPollTimeOptions);
			})();
		}
	});

	// Auto-mark calendar conflicts as unavailable (only if no existing response)
	$effect(() => {
		if ($calendarConflicts.size > 0 && myParticipant) {
			const updated = { ...localResponses };
			let hasChanges = false;
			for (const conflictId of $calendarConflicts) {
				if (!updated[conflictId]) {
					updated[conflictId] = 'unavailable';
					hasChanges = true;
				}
			}
			if (hasChanges) {
				localResponses = updated;
			}
		}
	});

	function getResponsesForTimeOption(timeOptionId: string) {
		const responses = $currentPollResponses.filter((r) => r.time_option_id === timeOptionId);
		return {
			available: responses.filter((r) => r.status === 'available').length,
			maybe: responses.filter((r) => r.status === 'maybe').length,
			unavailable: responses.filter((r) => r.status === 'unavailable').length,
			total: responses.length
		};
	}

	function formatDateTime(isoString: string) {
		const date = new Date(isoString);
		return {
			date: date.toLocaleDateString('en-US', {
				weekday: 'short',
				month: 'short',
				day: 'numeric'
			}),
			time: date.toLocaleTimeString('en-US', {
				hour: 'numeric',
				minute: '2-digit'
			})
		};
	}

	async function handleJoinPoll() {
		if (!$user && !anonymousName.trim()) {
			joinError = 'Please enter your name';
			return;
		}

		joiningPoll = true;
		joinError = '';

		try {
			await joinPoll(pollId, anonymousName.trim() || undefined);
			// Reload to get updated participant list
			await loadPoll(pollId);
		} catch (err) {
			joinError = err instanceof Error ? err.message : 'Failed to join poll';
		} finally {
			joiningPoll = false;
		}
	}

	function setResponse(timeOptionId: string, status: AvailabilityStatus) {
		localResponses = { ...localResponses, [timeOptionId]: status };
	}

	function validateComment(value: string) {
		if (value.length > MAX_COMMENT_LENGTH) {
			commentError = `Comment must be ${MAX_COMMENT_LENGTH} characters or less`;
			return false;
		}
		commentError = '';
		return true;
	}

	function handleCommentChange(value: string) {
		localComment = value;
		validateComment(value);
	}

	async function saveResponses() {
		if (!myParticipant) return;

		// Validate comment before saving
		if (!validateComment(localComment)) {
			return;
		}

		savingResponses = true;

		try {
			// Guests can save their comment; availability needs the guest save command (F06/F10).
			if (!isGuest) {
				for (const [timeOptionId, status] of Object.entries(localResponses)) {
					await submitAvailability(myParticipant.id, timeOptionId, status);
				}
			}
			// Save comment (trimmed, null if empty)
			const trimmedComment = localComment.trim();
			await updateParticipantComment(myParticipant.id, trimmedComment || null);
			// Reload to get updated responses
			await loadPoll(pollId);
		} catch (err) {
			console.error('Failed to save responses:', err);
		} finally {
			savingResponses = false;
		}
	}

	async function closePoll() {
		if (confirm('Are you sure you want to close this poll? Once closed, participants will no longer be able to submit or modify their availability.')) {
			await updatePollStatus(pollId, 'closed');
		}
	}

	function copyShareCode() {
		navigator.clipboard.writeText($currentPoll?.share_code || '');
		codeCopied = true;
		setTimeout(() => {
			codeCopied = false;
		}, 2000);
	}

	function copyShareLink() {
		const url = window.location.href;
		navigator.clipboard.writeText(url);
		linkCopied = true;
		setTimeout(() => {
			linkCopied = false;
		}, 2000);
	}

	async function selectFinalDate(timeOption: typeof $currentPollTimeOptions[0]) {
		// Format the date for display
		const startDate = new Date(timeOption.start_time);
		const endDate = new Date(timeOption.end_time);

		const dateStr = startDate.toLocaleDateString('en-US', {
			month: 'long',
			day: 'numeric',
			year: 'numeric'
		});

		let dateTimeStr;
		if (timeOption.is_all_day) {
			dateTimeStr = dateStr;
		} else {
			const startTime = startDate.toLocaleTimeString('en-US', {
				hour: 'numeric',
				minute: '2-digit'
			});
			const endTime = endDate.toLocaleTimeString('en-US', {
				hour: 'numeric',
				minute: '2-digit'
			});
			dateTimeStr = `${dateStr} ${startTime} - ${endTime}`;
		}

		if (!confirm(`Set ${dateTimeStr} as the final meeting time? All participants will be notified.`)) {
			return;
		}

		selectingFinalDate = true;
		try {
			await setSelectedFinalDate(pollId, timeOption.start_time, timeOption.end_time);
		} catch (err) {
			console.error('Failed to set final date:', err);
			alert('Failed to set final date. Please try again.');
		} finally {
			selectingFinalDate = false;
		}
	}

	function addToCalendarICS() {
		if (!$currentPoll?.selected_start_time || !$currentPoll.selected_end_time) return;

		const icsContent = generateICS({
			title: $currentPoll.title,
			description: $currentPoll.description || undefined,
			location: $currentPoll.location || undefined,
			startTime: $currentPoll.selected_start_time,
			endTime: $currentPoll.selected_end_time
		});

		const filename = `${$currentPoll.title.replace(/[^a-z0-9]/gi, '_').toLowerCase()}.ics`;
		downloadICS(icsContent, filename);
		showCalendarDropdown = false;
	}

	function addToGoogleCalendar() {
		if (!$currentPoll?.selected_start_time || !$currentPoll.selected_end_time) return;

		const url = generateGoogleCalendarUrl({
			title: $currentPoll.title,
			description: $currentPoll.description || undefined,
			location: $currentPoll.location || undefined,
			startTime: $currentPoll.selected_start_time,
			endTime: $currentPoll.selected_end_time
		});

		window.open(url, '_blank');
		showCalendarDropdown = false;
	}
</script>

<div class="poll-detail">
	{#if $calendarStatusError}
		<p role="status">{$calendarStatusError}</p>
	{/if}
	{#if $guestNotice}
		<p class="guest-notice" role="status">{$guestNotice}</p>
	{/if}
	{#if $pollsLoading && !$currentPoll}
		<div class="loading">Loading poll...</div>
	{:else if !$currentPoll}
		<div class="not-found">
			<h1>Poll not found</h1>
			<a href="/polls">Back to Polls</a>
		</div>
	{:else}
		<header>
			<a href="/polls" class="back-link">&larr; Back to Polls</a>
			<div class="poll-header">
				<div>
					<h1>{$currentPoll.title}</h1>
					<span class="status-badge status-{$currentPoll.status}">{$currentPoll.status}</span>
				</div>
			</div>
			{#if $currentPoll.description}
				<p class="description">{$currentPoll.description}</p>
			{/if}
			{#if $currentPoll.location}
				<p class="location">Location: {$currentPoll.location}</p>
			{/if}
			{#if $currentPoll.closes_at}
				{@const dueDate = new Date($currentPoll.closes_at)}
				{@const isPastDue = dueDate < new Date()}
				{@const isClosingSoon = !isPastDue && dueDate.getTime() - Date.now() < 24 * 60 * 60 * 1000}
				<p class="due-date {isPastDue ? 'past-due' : ''} {isClosingSoon ? 'closing-soon' : ''}">
					Response deadline: {dueDate.toLocaleDateString('en-US', {
						weekday: 'short',
						month: 'short',
						day: 'numeric',
						year: 'numeric'
					})}
					{#if isPastDue}
						(Past due)
					{:else if isClosingSoon}
						(Closes soon!)
					{/if}
				</p>
			{/if}
		</header>

		{#if $currentPoll.status === 'active'}
			<div class="share-section">
				<p>Share this poll with participants:</p>
				<div class="share-code-display">
					<div class="share-code-label">Share Code:</div>
					<div class="share-code-value">{$currentPoll.share_code}</div>
					<button class="btn secondary" onclick={copyShareCode}>
						{#if codeCopied}
							✓ Copied!
						{:else}
							Copy Code
						{/if}
					</button>
				</div>
				<div class="share-row">
					<input type="text" readonly value={typeof window !== 'undefined' ? window.location.href : ''} />
					<button class="btn secondary" onclick={copyShareLink}>
						{#if linkCopied}
							✓ Copied!
						{:else}
							Copy Link
						{/if}
					</button>
				</div>
			</div>
		{/if}

		{#if !myParticipant && $currentPoll.status === 'active'}
			<div class="join-prompt">
				<p>Join this poll to submit your availability</p>
				{#if !$user}
					<div class="anonymous-join">
						<input
							type="text"
							bind:value={anonymousName}
							placeholder="Enter your name"
							disabled={joiningPoll}
						/>
					</div>
				{/if}
				{#if joinError}
					<p class="error">{joinError}</p>
				{/if}
				<button class="btn primary" onclick={handleJoinPoll} disabled={joiningPoll}>
					{joiningPoll ? 'Joining...' : 'Join Poll'}
				</button>
			</div>
		{/if}

		{#if $currentPoll.selected_start_time && $currentPoll.selected_end_time}
			{@const selectedFormatted = formatDateTime($currentPoll.selected_start_time)}
			{@const selectedEndFormatted = formatDateTime($currentPoll.selected_end_time)}
			<div class="final-date-display">
				<div class="final-date-header">
					<h2>Final Meeting Time Selected</h2>
					<div class="calendar-dropdown-container">
						<button class="btn primary add-to-calendar-btn" onclick={() => (showCalendarDropdown = !showCalendarDropdown)}>
							📅 Add to Calendar
						</button>
						{#if showCalendarDropdown}
							<div class="calendar-dropdown">
								<button class="calendar-option" onclick={addToGoogleCalendar}>
									<span class="option-icon">🌐</span>
									<span>Google Calendar</span>
								</button>
								<button class="calendar-option" onclick={addToCalendarICS}>
									<span class="option-icon">📱</span>
									<span>Apple/Outlook Calendar</span>
								</button>
							</div>
						{/if}
					</div>
				</div>
				<div class="final-date-card">
					<div class="final-date-info">
						<div class="date">{selectedFormatted.date}</div>
						<div class="time">{selectedFormatted.time} - {selectedEndFormatted.time}</div>
					</div>
				</div>
			</div>
		{:else if isCreator && $currentPoll.status === 'closed'}
			<div class="final-date-selection">
				<h2>Select Final Meeting Time</h2>
				<p class="selection-prompt">Choose the best time based on availability:</p>
				<div class="time-options-list">
					{#each sortedTimeOptions as option}
						{@const formatted = formatDateTime(option.start_time)}
						{@const endFormatted = formatDateTime(option.end_time)}
						{@const stats = getResponsesForTimeOption(option.id)}

						<div class="time-option-card selectable" onclick={() => selectFinalDate(option)}>
							<div class="time-info">
								<div class="date">{formatted.date}</div>
								<div class="time">
									{#if option.is_all_day}
										All day
									{:else}
										{formatted.time} - {endFormatted.time}
									{/if}
								</div>
							</div>

							<div class="response-stats">
								<span class="stat available" title="Available">{stats.available}</span>
								<span class="stat maybe" title="Maybe">{stats.maybe}</span>
								<span class="stat unavailable" title="Unavailable">{stats.unavailable}</span>
							</div>

							<button class="select-btn" disabled={selectingFinalDate}>
								{selectingFinalDate ? 'Selecting...' : 'Select'}
							</button>
						</div>
					{/each}
				</div>
			</div>
		{/if}

		<div class="content-grid">
			<div class="availability-section">
				<h2>Time Options</h2>

				<div class="time-options-list">
					{#each $currentPollTimeOptions as option}
						{@const formatted = formatDateTime(option.start_time)}
						{@const endFormatted = formatDateTime(option.end_time)}
						{@const stats = getResponsesForTimeOption(option.id)}
						{@const myResponse = localResponses[option.id]}
						{@const hasCalendarConflict = $calendarConflicts.has(option.id)}

						<div class="time-option-card">
							<button
								class="time-info-button"
								onclick={() => goto(`/polls/${pollId}/times/${option.id}`)}
								title="View responses for this time option"
							>
								<div class="time-info">
                  <div class="time-header">
									  <div class="date">{formatted.date}</div>
                    {#if hasCalendarConflict}
										<span class="calendar-badge">📅 Busy</span>
									  {/if}
                  </div>
									<div class="time">
										{#if option.is_all_day}
											All day
										{:else}
											{formatted.time} - {endFormatted.time}
										{/if}
									</div>
								</div>

								<div class="response-stats">
									<span class="stat available" title="Available">{stats.available}</span>
									<span class="stat maybe" title="Maybe">{stats.maybe}</span>
									<span class="stat unavailable" title="Unavailable">{stats.unavailable}</span>
								</div>
							</button>

							{#if myParticipant && !isGuest && $currentPoll.status === 'active'}
								<div class="response-buttons">
									<button
										class="response-btn available"
										class:selected={myResponse === 'available'}
										onclick={() => setResponse(option.id, 'available')}
										title="Available"
									>
										✓
									</button>
									<button
										class="response-btn maybe"
										class:selected={myResponse === 'maybe'}
										onclick={() => setResponse(option.id, 'maybe')}
										title="Maybe"
									>
										?
									</button>
									<button
										class="response-btn unavailable"
										class:selected={myResponse === 'unavailable'}
										onclick={() => setResponse(option.id, 'unavailable')}
										title="Unavailable"
									>
										✗
									</button>
								</div>
							{/if}
						</div>
					{/each}
				</div>

				{#if myParticipant && $currentPoll.status === 'active'}
					{#if isGuest}
						<p class="guest-availability-note">
							Availability can't be saved as a guest yet. You can still leave a comment.
						</p>
					{/if}
					<div class="comment-section">
						<div class="comment-header">
							<label for="participant-comment" class="comment-label">Add a comment (optional)</label>
							<span class="comment-count">{localComment.length}/{MAX_COMMENT_LENGTH}</span>
						</div>
						<textarea
							id="participant-comment"
							value={localComment}
							onchange={(e) => handleCommentChange(e.currentTarget.value)}
							oninput={(e) => handleCommentChange(e.currentTarget.value)}
							placeholder="e.g., I'm flexible on timing, or I can only attend virtually..."
							rows="3"
							class="comment-textarea"
							maxlength={MAX_COMMENT_LENGTH}
						></textarea>
						{#if commentError}
							<p class="comment-error">{commentError}</p>
						{/if}
					</div>
					<div class="save-section">
						<button class="btn primary" onclick={saveResponses} disabled={savingResponses}>
							{savingResponses ? 'Saving...' : isGuest ? 'Save Comment' : 'Save Responses'}
						</button>
					</div>
				{/if}
			</div>

			<div class="participants-section">
				<h2>Participants ({$currentPollParticipants.length})</h2>
				{#if $currentPollParticipants.length === 0}
					<p class="no-participants">No participants yet</p>
				{:else}
					<ul class="participants-list">
						{#each $currentPollParticipants as participant}
							<li>
								<div class="participant-info">
									<div class="participant-header">
										<span class="participant-name">
											{participant.profiles?.display_name || participant.anonymous_name || 'Anonymous'}
										</span>
										{#if $user ? participant.user_id === $user.id : participant.id === $currentGuest?.participantId}
											<span class="you-badge">You</span>
										{/if}
									</div>
									{#if participant.comment}
										<p class="participant-comment">{participant.comment}</p>
									{/if}
								</div>
							</li>
						{/each}
					</ul>
				{/if}
			</div>
		</div>

		{#if isCreator && $currentPoll.status === 'active'}
			<div class="close-poll-section">
				<button class="btn secondary" onclick={closePoll}>Close Poll</button>
			</div>
		{/if}
	{/if}
</div>

<style>
	.poll-detail {
		max-width: 900px;
		margin: 0 auto;
		padding: 2rem;
	}

	.guest-notice,
	.guest-availability-note {
		padding: 0.75rem 1rem;
		border-radius: 8px;
		background: #fff8e1;
		color: #5d4400;
		font-size: 0.875rem;
	}

	.loading,
	.not-found {
		text-align: center;
		padding: 4rem;
	}

	.back-link {
		color: #666;
		text-decoration: none;
		font-size: 0.875rem;
	}

	.back-link:hover {
		color: #333;
	}

	.poll-header {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		margin-top: 0.5rem;
		gap: 1rem;
		flex-wrap: wrap;
	}

	.poll-header h1 {
		margin: 0;
		display: inline;
	}

	.status-badge {
		display: inline-block;
		padding: 0.25rem 0.5rem;
		border-radius: 4px;
		font-size: 0.75rem;
		font-weight: 500;
		text-transform: uppercase;
		margin-left: 0.5rem;
	}

	.status-draft {
		background: #f0f0f0;
		color: #666;
	}

	.status-active {
		background: #d4edda;
		color: #155724;
	}

	.status-closed {
		background: #fff3cd;
		color: #856404;
	}

	.description {
		color: #666;
		margin: 0.5rem 0;
	}

	.location {
		color: #666;
		font-size: 0.875rem;
		margin: 0.25rem 0;
	}

	.due-date {
		color: #666;
		font-size: 0.875rem;
		margin: 0.5rem 0;
		font-weight: 500;
	}

	.due-date.closing-soon {
		color: #ff8800;
		font-weight: 600;
	}

	.due-date.past-due {
		color: #cc0000;
		font-weight: 600;
	}

	.creator-actions {
		display: flex;
		gap: 0.5rem;
	}

	.share-section {
		background: #f8f9fa;
		padding: 1rem;
		border-radius: 8px;
		margin: 1.5rem 0;
	}

	.share-section p {
		margin: 0 0 0.75rem;
		font-size: 0.875rem;
		color: #666;
	}

	.share-code-display {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		background: white;
		padding: 1rem;
		border-radius: 6px;
		margin-bottom: 1rem;
		border: 2px solid #007bff;
	}

	.share-code-label {
		font-size: 0.875rem;
		color: #666;
		font-weight: 500;
	}

	.share-code-value {
		font-family: monospace;
		font-size: 1.5rem;
		font-weight: 700;
		letter-spacing: 0.15em;
		color: #007bff;
		flex: 1;
	}

	.share-row {
		display: flex;
		gap: 0.5rem;
	}

	.share-row input {
		flex: 1;
		padding: 0.5rem;
		border: 1px solid #ddd;
		border-radius: 4px;
		font-size: 0.875rem;
	}

	.content-grid {
		display: grid;
		grid-template-columns: 1fr 280px;
		gap: 2rem;
		margin-top: 2rem;
	}

	@media (max-width: 768px) {
		.content-grid {
			grid-template-columns: 1fr;
		}
	}

	.availability-section,
	.participants-section {
		background: white;
		border-radius: 8px;
		padding: 1.5rem;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
	}

	.availability-section h2,
	.participants-section h2 {
		margin: 0 0 1rem;
		font-size: 1.125rem;
	}

	.join-prompt {
		background: #f8f9fa;
		padding: 1rem;
		border-radius: 6px;
		margin: 1.5rem 0;
		text-align: center;
	}

	.join-prompt p {
		margin: 0 0 0.75rem;
	}

	.anonymous-join input {
		padding: 0.5rem;
		border: 1px solid #ddd;
		border-radius: 4px;
		margin-bottom: 0.75rem;
		width: 200px;
	}

	.error {
		color: #c00;
		font-size: 0.875rem;
	}

	.time-options-list {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.time-option-card {
		display: flex;
		align-items: center;
		gap: 1rem;
		padding: 1rem;
		border: 1px solid #eee;
		border-radius: 6px;
		flex-wrap: wrap;
	}

	.time-info-button {
		display: flex;
		align-items: center;
		gap: 1rem;
		flex: 1;
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		text-align: left;
		transition: opacity 0.15s;
	}

	.time-info-button:hover {
		opacity: 0.7;
	}

	.time-info {
		flex: 1;
		min-width: 150px;
	}

	.time-info .date {
		font-weight: 500;
	}

	.time-header {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}

	.calendar-badge {
		background: #fff3cd;
		color: #856404;
		font-size: 0.75rem;
		padding: 0.25rem 0.5rem;
		border-radius: 4px;
		white-space: nowrap;
	}

	.time-info .time {
		font-size: 0.875rem;
		color: #666;
	}

	.response-stats {
		display: flex;
		gap: 0.5rem;
	}

	.stat {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		border-radius: 50%;
		font-size: 0.75rem;
		font-weight: 500;
	}

	.stat.available {
		background: #d4edda;
		color: #155724;
	}

	.stat.maybe {
		background: #fff3cd;
		color: #856404;
	}

	.stat.unavailable {
		background: #f8d7da;
		color: #721c24;
	}

	.response-buttons {
		display: flex;
		gap: 0.25rem;
	}

	.response-btn {
		width: 36px;
		height: 36px;
		border: 2px solid #ddd;
		border-radius: 6px;
		background: white;
		cursor: pointer;
		font-size: 1rem;
		transition: all 0.15s;
	}

	.response-btn:hover {
		border-color: #999;
	}

	.response-btn.available.selected {
		background: #d4edda;
		border-color: #28a745;
		color: #155724;
	}

	.response-btn.maybe.selected {
		background: #fff3cd;
		border-color: #ffc107;
		color: #856404;
	}

	.response-btn.unavailable.selected {
		background: #f8d7da;
		border-color: #dc3545;
		color: #721c24;
	}

	.comment-section {
		margin-top: 1.5rem;
		padding-top: 1rem;
		border-top: 1px solid #eee;
	}

	.comment-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 0.5rem;
	}

	.comment-label {
		font-size: 0.875rem;
		font-weight: 500;
		color: #333;
	}

	.comment-count {
		font-size: 0.75rem;
		color: #666;
	}

	.comment-textarea {
		width: 100%;
		padding: 0.75rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 0.875rem;
		font-family: inherit;
		resize: vertical;
		min-height: 80px;
	}

	.comment-textarea:focus {
		outline: none;
		border-color: #007bff;
		box-shadow: 0 0 0 3px rgba(0, 123, 255, 0.1);
	}

	.comment-textarea::placeholder {
		color: #999;
	}

	.comment-error {
		font-size: 0.8125rem;
		color: #c00;
		margin: 0.5rem 0 0 0;
	}

	.save-section {
		margin-top: 1rem;
		text-align: right;
	}

	.close-poll-section {
		margin-top: 2rem;
		padding-top: 2rem;
		border-top: 1px solid #eee;
		text-align: center;
	}

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
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.participant-header {
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

	.btn {
		padding: 0.5rem 1rem;
		border-radius: 6px;
		font-size: 0.875rem;
		font-weight: 500;
		cursor: pointer;
		border: none;
		transition: all 0.2s ease;
	}

	.btn.primary {
		background: #007bff;
		color: white;
	}

	.btn.primary:hover:not(:disabled) {
		background: #0056b3;
	}

	.btn.secondary {
		background: #f5f5f5;
		color: #333;
	}

	.btn.secondary:hover {
		background: #e5e5e5;
	}

	.btn:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.final-date-display,
	.final-date-selection {
		background: white;
		border-radius: 8px;
		padding: 1.5rem;
		margin: 1.5rem 0;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
	}

	.final-date-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 1rem;
		gap: 1rem;
		flex-wrap: wrap;
	}

	.final-date-display h2,
	.final-date-selection h2 {
		margin: 0;
		font-size: 1.25rem;
		color: #333;
	}

	.final-date-card {
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		border-radius: 8px;
		padding: 1.5rem;
		color: white;
	}

	.final-date-info .date {
		font-size: 1.5rem;
		font-weight: 600;
		margin-bottom: 0.5rem;
	}

	.final-date-info .time {
		font-size: 1.125rem;
		opacity: 0.95;
	}

	.selection-prompt {
		margin: 0 0 1rem;
		color: #666;
		font-size: 0.875rem;
	}

	.time-option-card.selectable {
		cursor: pointer;
		transition: all 0.2s ease;
		border: 2px solid #eee;
	}

	.time-option-card.selectable:hover {
		border-color: #667eea;
		box-shadow: 0 2px 8px rgba(102, 126, 234, 0.2);
		transform: translateY(-1px);
	}

	.select-btn {
		padding: 0.5rem 1rem;
		background: #667eea;
		color: white;
		border: none;
		border-radius: 6px;
		font-size: 0.875rem;
		font-weight: 500;
		cursor: pointer;
		transition: background 0.2s;
	}

	.select-btn:hover:not(:disabled) {
		background: #5568d3;
	}

	.select-btn:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.calendar-dropdown-container {
		position: relative;
	}

	.add-to-calendar-btn {
		white-space: nowrap;
	}

	.calendar-dropdown {
		position: absolute;
		top: 100%;
		right: 0;
		margin-top: 0.5rem;
		background: white;
		border: 1px solid #ddd;
		border-radius: 6px;
		box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
		min-width: 220px;
		overflow: hidden;
		z-index: 10;
	}

	.calendar-option {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		width: 100%;
		padding: 0.75rem 1rem;
		background: white;
		border: none;
		cursor: pointer;
		font-size: 0.875rem;
		text-align: left;
		transition: background 0.15s;
	}

	.calendar-option:hover {
		background: #f8f9fa;
	}

	.calendar-option:not(:last-child) {
		border-bottom: 1px solid #eee;
	}

	.option-icon {
		font-size: 1.125rem;
	}
</style>

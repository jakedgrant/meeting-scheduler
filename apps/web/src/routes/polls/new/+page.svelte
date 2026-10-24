<script lang="ts">
	import { onDestroy } from 'svelte';
	import { goto } from '$app/navigation';
	import { user } from '$lib/stores/auth';
	import { createPoll } from '$lib/stores/polls';
	import { createPollCreation } from '$lib/poll-creation';
	const creation = createPollCreation({ create: createPoll });
	onDestroy(() => creation.invalidate());
	$effect(() => { creation.setOwner($user?.id ?? null); });

	// Redirect if not authenticated
	$effect(() => {
		if ($user === null) {
			goto('/auth');
		}
	});

	let title = $derived($creation.draft.title);
	let description = $derived($creation.draft.description);
	let location = $derived($creation.draft.location);
	let dueDate = $derived($creation.draft.dueDate);
	let isAllDay = $derived($creation.draft.isAllDay);
	let timeOptions = $derived($creation.draft.timeOptions);
	let useDateRange = $state(false);
	let loading = $derived($creation.saving);
	let locked = $derived(loading || $creation.uncertain || $creation.recoveryRequired);
	let error = $state('');
	type TimeOption = typeof timeOptions[number];

	// Date range fields
	let rangeStartDate = $state('');
	let rangeEndDate = $state('');
	let rangeStartTime = $state('09:00');
	let rangeEndTime = $state('10:00');

	function addTimeOption() {
		creation.edit({ timeOptions: [
			...timeOptions,
			{ id: crypto.randomUUID(), date: '', startTime: '09:00', endTime: '10:00' }
		] });
	}

	function removeTimeOption(id: string) {
		if (timeOptions.length > 1) {
			creation.edit({ timeOptions: timeOptions.filter((opt) => opt.id !== id) });
		}
	}

	function addDateRange() {
		if (!rangeStartDate || !rangeEndDate) {
			error = 'Please select both start and end dates for the range';
			return;
		}

		const startDate = new Date(rangeStartDate);
		const endDate = new Date(rangeEndDate);

		if (startDate > endDate) {
			error = 'Start date must be before or equal to end date';
			return;
		}

		// Validate time range if not all-day
		if (!isAllDay && isInvalidTimeRange(rangeStartTime, rangeEndTime)) {
			error = 'End time must be after start time';
			return;
		}

		// Generate time options for each date in the range
		const newOptions: TimeOption[] = [];
		const currentDate = new Date(startDate);

		while (currentDate <= endDate) {
			newOptions.push({
				id: crypto.randomUUID(),
				date: currentDate.toISOString().split('T')[0],
				startTime: rangeStartTime,
				endTime: rangeEndTime
			});
			currentDate.setDate(currentDate.getDate() + 1);
		}

		// Add all new options to the list and sort chronologically
		creation.edit({ timeOptions: [...timeOptions.filter(option => option.date), ...newOptions].sort((a, b) => {
			const dateA = new Date(`${a.date}T${a.startTime}`);
			const dateB = new Date(`${b.date}T${b.startTime}`);
			return dateA.getTime() - dateB.getTime();
		}) });

		// Reset the range fields
		rangeStartDate = '';
		rangeEndDate = '';
		rangeStartTime = '09:00';
		rangeEndTime = '10:00';
		error = '';
	}

	function updateTimeOption(id: string, field: keyof TimeOption, value: string) {
		creation.edit({ timeOptions: timeOptions.map((opt) => {
			if (opt.id !== id) return opt;

			const updated = { ...opt, [field]: value };

			// Auto-adjust end time if start time is changed to be >= end time
			if (field === 'startTime' && isInvalidTimeRange(value, updated.endTime)) {
				updated.endTime = incrementTime(value, 15);
			}

			return updated;
		}) });
	}

	// Helper function to check if end time is before or equal to start time
	function isInvalidTimeRange(startTime: string, endTime: string): boolean {
		const [startHour, startMin] = startTime.split(':').map(Number);
		const [endHour, endMin] = endTime.split(':').map(Number);
		const startMinutes = startHour * 60 + startMin;
		const endMinutes = endHour * 60 + endMin;
		return endMinutes <= startMinutes;
	}

	// Get valid end time options (only times after the start time)
	function getValidEndTimeOptions(startTime: string): string[] {
		return timePickerOptions.filter((time) => !isInvalidTimeRange(startTime, time));
	}

	async function handleSubmit() {
		error = '';
		const result = await creation.submit();
		if (result) goto(`/polls/${result.poll.id}`);
	}

	// Generate next 14 days for date picker
	function getDateOptions(): { value: string; label: string }[] {
		const options = [];
		const today = new Date();
		for (let i = 0; i < 14; i++) {
			const date = new Date(today);
			date.setDate(today.getDate() + i);
			const value = date.toISOString().split('T')[0];
			const label = date.toLocaleDateString('en-US', {
				weekday: 'short',
				month: 'short',
				day: 'numeric'
			});
			options.push({ value, label });
		}
		return options;
	}

	const dateOptions = getDateOptions();

	// Generate time options in 15-minute increments
	function getTimeOptions(): string[] {
		const options = [];
		for (let hour = 0; hour < 24; hour++) {
			for (let minute = 0; minute < 60; minute += 15) {
				const timeStr = `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`;
				options.push(timeStr);
			}
		}
		return options;
	}

	const timePickerOptions = getTimeOptions();

	// Helper functions for spinner buttons
	function incrementTime(time: string, minutes: number): string {
		const [hours, mins] = time.split(':').map(Number);
		const totalMinutes = hours * 60 + mins + minutes;
		const newHours = Math.floor((totalMinutes / 60) % 24);
		const newMins = totalMinutes % 60;
		return `${newHours.toString().padStart(2, '0')}:${newMins.toString().padStart(2, '0')}`;
	}

	function adjustTime(id: string, field: 'startTime' | 'endTime', direction: 'up' | 'down') {
		const option = timeOptions.find((opt) => opt.id === id);
		if (!option) return;

		const currentTime = option[field];
		const minutes = direction === 'up' ? 15 : -15;
		const newTime = incrementTime(currentTime, minutes);

		// For end time, prevent going to or before start time
		if (field === 'endTime' && direction === 'down') {
			if (isInvalidTimeRange(option.startTime, newTime)) {
				return; // Don't allow adjustment
			}
		}

		updateTimeOption(id, field, newTime);
	}
</script>

<div class="create-poll">
	<header>
		<a href="/polls" class="back-link">&larr; Back to Polls</a>
		<h1>Create New Poll</h1>
	</header>

	<form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }}>
		{#if error || $creation.error}
			<div class="error" role="alert">{error || $creation.error}</div>
		{/if}

		<div class="form-section">
			<h2>Poll Details</h2>

			<div class="form-group">
				<label for="title">Title *</label>
				<input
					id="title"
					type="text"
					value={title}
					oninput={(event) => creation.edit({ title: event.currentTarget.value })}
					placeholder="e.g., Team Sync Meeting"
					disabled={locked}
				/>
			</div>

			<div class="form-group">
				<label for="description">Description</label>
				<textarea
					id="description"
					value={description}
					oninput={(event) => creation.edit({ description: event.currentTarget.value })}
					placeholder="What's this meeting about?"
					rows="3"
					disabled={locked}
				></textarea>
			</div>

			<div class="form-group">
				<label for="location">Location</label>
				<input
					id="location"
					type="text"
					value={location}
					oninput={(event) => creation.edit({ location: event.currentTarget.value })}
					placeholder="e.g., Zoom, Conference Room A"
					disabled={locked}
				/>
			</div>

			<div class="form-group">
				<label for="due-date">Response Due Date (Optional)</label>
				<input
					id="due-date"
					type="date"
					value={dueDate}
					oninput={(event) => creation.edit({ dueDate: event.currentTarget.value })}
					min={new Date().toISOString().split('T')[0]}
					disabled={locked}
				/>
				<p class="help-text">Set a deadline for participants to respond by</p>
			</div>

			<div class="form-group checkbox-group">
				<label>
					<input
						type="checkbox"
						checked={$creation.draft.useEventPass}
						onchange={(event) => creation.edit({ useEventPass: event.currentTarget.checked })}
						disabled={locked}
					/>
					Use an event pass for this poll
				</label>
				<p class="help-text">Use your oldest available pass for this poll. If your subscription covers the poll, your pass is kept.</p>
			</div>

			<div class="form-group checkbox-group">
				<label>
					<input
						type="checkbox"
						checked={isAllDay}
						onchange={(event) => creation.edit({ isAllDay: event.currentTarget.checked })}
						disabled={locked}
					/>
					All-day events
				</label>
				<p class="help-text">Time options will be for entire days instead of specific time ranges</p>
			</div>
		</div>

		<div class="form-section">
			<h2>Time Options</h2>
			<p class="hint">Add the time slots participants can choose from.</p>

			<div class="form-group checkbox-group">
				<label>
					<input
						type="checkbox"
						bind:checked={useDateRange}
						disabled={locked}
					/>
					Use date range selector
				</label>
				<p class="help-text">Quickly add multiple days with the same time slots</p>
			</div>

			{#if useDateRange}
				<div class="date-range-selector">
					<h3>Add Date Range</h3>
					<div class="range-inputs">
						<div class="range-row">
							<div class="range-field">
								<label for="range-start-date">Start Date</label>
								<select
									id="range-start-date"
									bind:value={rangeStartDate}
									disabled={locked}
								>
									<option value="">Select start date</option>
									{#each dateOptions as dateOpt}
										<option value={dateOpt.value}>{dateOpt.label}</option>
									{/each}
								</select>
							</div>
							<div class="range-field">
								<label for="range-end-date">End Date</label>
								<select
									id="range-end-date"
									bind:value={rangeEndDate}
									disabled={locked}
								>
									<option value="">Select end date</option>
									{#each dateOptions as dateOpt}
										<option value={dateOpt.value}>{dateOpt.label}</option>
									{/each}
								</select>
							</div>
						</div>

						{#if !isAllDay}
							<div class="range-row">
								<div class="range-field">
									<label for="range-start-time">Start Time</label>
									<div class="time-input-group">
										<button
											type="button"
											class="spinner-btn"
											onclick={() => { rangeStartTime = incrementTime(rangeStartTime, 15); }}
											disabled={locked}
											title="Increase start time"
										>
											&#9650;
										</button>
										<select
											id="range-start-time"
											bind:value={rangeStartTime}
											disabled={locked}
											class="time-select"
										>
											{#each timePickerOptions as timeOpt}
												<option value={timeOpt}>{timeOpt}</option>
											{/each}
										</select>
										<button
											type="button"
											class="spinner-btn"
											onclick={() => { rangeStartTime = incrementTime(rangeStartTime, -15); }}
											disabled={locked}
											title="Decrease start time"
										>
											&#9660;
										</button>
									</div>
								</div>
								<div class="range-field">
									<label for="range-end-time">End Time</label>
									<div class="time-input-group">
										<button
											type="button"
											class="spinner-btn"
											onclick={() => { rangeEndTime = incrementTime(rangeEndTime, 15); }}
											disabled={locked}
											title="Increase end time"
										>
											&#9650;
										</button>
										<select
											id="range-end-time"
											bind:value={rangeEndTime}
											disabled={locked}
											class="time-select"
										>
											{#each getValidEndTimeOptions(rangeStartTime) as timeOpt}
												<option value={timeOpt}>{timeOpt}</option>
											{/each}
										</select>
										<button
											type="button"
											class="spinner-btn"
											onclick={() => { rangeEndTime = incrementTime(rangeEndTime, -15); }}
											disabled={locked}
											title="Decrease end time"
										>
											&#9660;
										</button>
									</div>
								</div>
							</div>
						{/if}

						<button type="button" class="btn primary add-range-btn" onclick={addDateRange} disabled={locked}>
							Add Date Range
						</button>
					</div>
				</div>
			{/if}

			<div class="time-options">
				{#each timeOptions as option (option.id)}
					<div class="time-option">
						<select
							value={option.date}
							onchange={(e) => updateTimeOption(option.id, 'date', e.currentTarget.value)}
							disabled={locked}
						>
							<option value="">Select date</option>
							{#each dateOptions as dateOpt}
								<option value={dateOpt.value}>{dateOpt.label}</option>
							{/each}
						</select>

						{#if !isAllDay}
							<div class="time-input-group">
								<button
									type="button"
									class="spinner-btn"
									onclick={() => adjustTime(option.id, 'startTime', 'up')}
									disabled={locked}
									title="Increase start time"
								>
									&#9650;
								</button>
								<select
									value={option.startTime}
									onchange={(e) => updateTimeOption(option.id, 'startTime', e.currentTarget.value)}
									disabled={locked}
									class="time-select"
								>
									{#each timePickerOptions as timeOpt}
										<option value={timeOpt}>{timeOpt}</option>
									{/each}
								</select>
								<button
									type="button"
									class="spinner-btn"
									onclick={() => adjustTime(option.id, 'startTime', 'down')}
									disabled={locked}
									title="Decrease start time"
								>
									&#9660;
								</button>
							</div>

							<span class="time-separator">to</span>

							<div class="time-input-group">
								<button
									type="button"
									class="spinner-btn"
									onclick={() => adjustTime(option.id, 'endTime', 'up')}
									disabled={locked}
									title="Increase end time"
								>
									&#9650;
								</button>
								<select
									value={option.endTime}
									onchange={(e) => updateTimeOption(option.id, 'endTime', e.currentTarget.value)}
									disabled={locked}
									class="time-select"
								>
									{#each getValidEndTimeOptions(option.startTime) as timeOpt}
										<option value={timeOpt}>{timeOpt}</option>
									{/each}
								</select>
								<button
									type="button"
									class="spinner-btn"
									onclick={() => adjustTime(option.id, 'endTime', 'down')}
									disabled={locked}
									title="Decrease end time"
								>
									&#9660;
								</button>
							</div>
						{/if}

						<button
							type="button"
							class="remove-btn"
							onclick={() => removeTimeOption(option.id)}
							disabled={locked || timeOptions.length <= 1}
							title="Remove time option"
						>
							&times;
						</button>
					</div>
				{/each}
			</div>

			<button type="button" class="add-time-btn" onclick={addTimeOption} disabled={locked}>
				+ Add another time
			</button>
		</div>

		<div class="form-actions">
			<a href="/polls" class="btn secondary">Cancel</a>
			<button type="submit" class="btn primary" disabled={loading || !$creation.ownerId || $creation.recoveryRequired}>
				{loading ? 'Creating...' : $creation.error ? 'Retry Create Poll' : 'Create Poll'}
			</button>
		</div>
	</form>
</div>

<style>
	.create-poll {
		max-width: 600px;
		margin: 0 auto;
		padding: 2rem;
	}

	header {
		margin-bottom: 2rem;
	}

	.back-link {
		color: #666;
		text-decoration: none;
		font-size: 0.875rem;
	}

	.back-link:hover {
		color: #333;
	}

	h1 {
		margin: 0.5rem 0 0;
	}

	.error {
		background: #fee;
		color: #c00;
		padding: 0.75rem;
		border-radius: 6px;
		margin-bottom: 1rem;
	}
	.form-section {
		background: white;
		border-radius: 8px;
		padding: 1.5rem;
		margin-bottom: 1.5rem;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
	}

	.form-section h2 {
		margin: 0 0 1rem;
		font-size: 1.125rem;
	}

	.hint {
		margin: -0.5rem 0 1rem;
		font-size: 0.875rem;
		color: #666;
	}

	.form-group {
		margin-bottom: 1rem;
	}

	label {
		display: block;
		margin-bottom: 0.5rem;
		font-weight: 500;
	}

	input[type='text'],
	textarea,
	select {
		width: 100%;
		padding: 0.75rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
		font-family: inherit;
	}

	input:focus,
	textarea:focus,
	select:focus {
		outline: none;
		border-color: #007bff;
	}

	.time-options {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.time-option {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		flex-wrap: wrap;
	}

	.time-option > select {
		flex: 1;
		min-width: 150px;
	}

	.time-input-group {
		display: flex;
		align-items: center;
		gap: 0.25rem;
		background: #f8f9fa;
		border: 1px solid #ddd;
		border-radius: 6px;
		padding: 0.25rem;
	}

	.time-select {
		width: auto;
		min-width: 80px;
		padding: 0.5rem;
		border: none;
		background: white;
		border-radius: 4px;
	}

	.spinner-btn {
		background: white;
		border: 1px solid #ddd;
		border-radius: 4px;
		cursor: pointer;
		padding: 0.25rem 0.5rem;
		font-size: 0.75rem;
		color: #666;
		line-height: 1;
		transition: all 0.2s;
	}

	.spinner-btn:hover:not(:disabled) {
		background: #007bff;
		color: white;
		border-color: #007bff;
	}

	.spinner-btn:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.time-separator {
		color: #666;
	}

	.remove-btn {
		background: none;
		border: none;
		font-size: 1.5rem;
		color: #999;
		cursor: pointer;
		padding: 0 0.5rem;
		line-height: 1;
	}

	.remove-btn:hover:not(:disabled) {
		color: #c00;
	}

	.remove-btn:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.add-time-btn {
		margin-top: 0.75rem;
		padding: 0.5rem 1rem;
		background: #f5f5f5;
		border: 1px dashed #ccc;
		border-radius: 6px;
		cursor: pointer;
		font-size: 0.875rem;
		color: #666;
	}

	.add-time-btn:hover:not(:disabled) {
		background: #eee;
		border-color: #999;
	}

	.form-actions {
		display: flex;
		justify-content: flex-end;
		gap: 1rem;
	}

	.btn {
		padding: 0.75rem 1.5rem;
		border-radius: 6px;
		font-size: 1rem;
		font-weight: 500;
		text-decoration: none;
		cursor: pointer;
		border: none;
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

	.checkbox-group label {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		cursor: pointer;
		font-weight: 500;
	}

	.checkbox-group input[type='checkbox'] {
		width: auto;
		cursor: pointer;
	}

	.help-text {
		margin: 0.5rem 0 0 1.75rem;
		font-size: 0.875rem;
		color: #666;
	}

	.date-range-selector {
		background: #f8f9fa;
		border: 1px solid #e0e0e0;
		border-radius: 8px;
		padding: 1rem;
		margin-bottom: 1rem;
	}

	.date-range-selector h3 {
		margin: 0 0 1rem;
		font-size: 1rem;
		color: #333;
	}

	.range-inputs {
		display: flex;
		flex-direction: column;
		gap: 1rem;
	}

	.range-row {
		display: flex;
		gap: 1rem;
		flex-wrap: wrap;
	}

	.range-field {
		flex: 1;
		min-width: 200px;
	}

	.range-field label {
		font-size: 0.875rem;
		margin-bottom: 0.25rem;
	}

	.add-range-btn {
		align-self: flex-start;
		margin-top: 0.5rem;
	}
</style>

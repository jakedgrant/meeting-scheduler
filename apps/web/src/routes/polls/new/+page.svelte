<script lang="ts">
	import { goto } from '$app/navigation';
	import { user } from '$lib/stores/auth';
	import { createPoll, addTimeOptions } from '$lib/stores/polls';

	// Redirect if not authenticated
	$effect(() => {
		if ($user === null) {
			goto('/auth');
		}
	});

	let title = $state('');
	let description = $state('');
	let location = $state('');
	let loading = $state(false);
	let error = $state('');

	// Time options
	interface TimeOption {
		id: string;
		date: string;
		startTime: string;
		endTime: string;
	}

	let timeOptions = $state<TimeOption[]>([
		{ id: crypto.randomUUID(), date: '', startTime: '09:00', endTime: '10:00' }
	]);

	function addTimeOption() {
		timeOptions = [
			...timeOptions,
			{ id: crypto.randomUUID(), date: '', startTime: '09:00', endTime: '10:00' }
		];
	}

	function removeTimeOption(id: string) {
		if (timeOptions.length > 1) {
			timeOptions = timeOptions.filter((opt) => opt.id !== id);
		}
	}

	function updateTimeOption(id: string, field: keyof TimeOption, value: string) {
		timeOptions = timeOptions.map((opt) => {
			if (opt.id !== id) return opt;

			const updated = { ...opt, [field]: value };

			// Auto-adjust end time if start time is changed to be >= end time
			if (field === 'startTime' && isInvalidTimeRange(value, updated.endTime)) {
				updated.endTime = incrementTime(value, 15);
			}

			return updated;
		});
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
		if (!title.trim()) {
			error = 'Please enter a poll title';
			return;
		}

		const validTimeOptions = timeOptions.filter((opt) => opt.date && opt.startTime && opt.endTime);
		if (validTimeOptions.length === 0) {
			error = 'Please add at least one time option';
			return;
		}

		// Check for invalid time ranges
		const invalidOption = validTimeOptions.find((opt) =>
			isInvalidTimeRange(opt.startTime, opt.endTime)
		);
		if (invalidOption) {
			error = 'End time must be after start time for all time options';
			return;
		}

		loading = true;
		error = '';

		try {
			// Create the poll
			const poll = await createPoll({
				title: title.trim(),
				description: description.trim() || undefined,
				location: location.trim() || undefined
			});

			if (!poll) {
				throw new Error('Failed to create poll');
			}

			// Add time options
			const formattedOptions = validTimeOptions.map((opt) => ({
				start_time: new Date(`${opt.date}T${opt.startTime}`).toISOString(),
				end_time: new Date(`${opt.date}T${opt.endTime}`).toISOString()
			}));

			await addTimeOptions(poll.id, formattedOptions);

			// Redirect to the poll detail page
			goto(`/polls/${poll.id}`);
		} catch (err) {
			console.error('Failed to create poll:', err);
			error = err instanceof Error ? err.message : 'Failed to create poll';
		} finally {
			loading = false;
		}
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
		{#if error}
			<div class="error">{error}</div>
		{/if}

		<div class="form-section">
			<h2>Poll Details</h2>

			<div class="form-group">
				<label for="title">Title *</label>
				<input
					id="title"
					type="text"
					bind:value={title}
					placeholder="e.g., Team Sync Meeting"
					disabled={loading}
				/>
			</div>

			<div class="form-group">
				<label for="description">Description</label>
				<textarea
					id="description"
					bind:value={description}
					placeholder="What's this meeting about?"
					rows="3"
					disabled={loading}
				></textarea>
			</div>

			<div class="form-group">
				<label for="location">Location</label>
				<input
					id="location"
					type="text"
					bind:value={location}
					placeholder="e.g., Zoom, Conference Room A"
					disabled={loading}
				/>
			</div>
		</div>

		<div class="form-section">
			<h2>Time Options</h2>
			<p class="hint">Add the time slots participants can choose from.</p>

			<div class="time-options">
				{#each timeOptions as option (option.id)}
					<div class="time-option">
						<select
							value={option.date}
							onchange={(e) => updateTimeOption(option.id, 'date', e.currentTarget.value)}
							disabled={loading}
						>
							<option value="">Select date</option>
							{#each dateOptions as dateOpt}
								<option value={dateOpt.value}>{dateOpt.label}</option>
							{/each}
						</select>

						<div class="time-input-group">
							<button
								type="button"
								class="spinner-btn"
								onclick={() => adjustTime(option.id, 'startTime', 'up')}
								disabled={loading}
								title="Increase start time"
							>
								&#9650;
							</button>
							<select
								value={option.startTime}
								onchange={(e) => updateTimeOption(option.id, 'startTime', e.currentTarget.value)}
								disabled={loading}
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
								disabled={loading}
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
								disabled={loading}
								title="Increase end time"
							>
								&#9650;
							</button>
							<select
								value={option.endTime}
								onchange={(e) => updateTimeOption(option.id, 'endTime', e.currentTarget.value)}
								disabled={loading}
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
								disabled={loading}
								title="Decrease end time"
							>
								&#9660;
							</button>
						</div>

						<button
							type="button"
							class="remove-btn"
							onclick={() => removeTimeOption(option.id)}
							disabled={loading || timeOptions.length <= 1}
							title="Remove time option"
						>
							&times;
						</button>
					</div>
				{/each}
			</div>

			<button type="button" class="add-time-btn" onclick={addTimeOption} disabled={loading}>
				+ Add another time
			</button>
		</div>

		<div class="form-actions">
			<a href="/polls" class="btn secondary">Cancel</a>
			<button type="submit" class="btn primary" disabled={loading}>
				{loading ? 'Creating...' : 'Create Poll'}
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
</style>

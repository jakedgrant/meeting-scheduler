<script lang="ts">
	import { goto } from '$app/navigation';
	import { user, profile, updateProfile } from '$lib/stores/auth';

	let displayName = $state('');
	let avatarUrl = $state('');
	let timezone = $state('UTC');
	let loading = $state(false);
	let errorMessage = $state('');
	let successMessage = $state('');

	// Common timezones for the dropdown
	const timezones = [
		'UTC',
		'America/New_York',
		'America/Chicago',
		'America/Denver',
		'America/Los_Angeles',
		'America/Phoenix',
		'America/Anchorage',
		'Pacific/Honolulu',
		'Europe/London',
		'Europe/Paris',
		'Europe/Berlin',
		'Europe/Rome',
		'Europe/Madrid',
		'Asia/Dubai',
		'Asia/Kolkata',
		'Asia/Singapore',
		'Asia/Tokyo',
		'Asia/Hong_Kong',
		'Asia/Shanghai',
		'Australia/Sydney',
		'Australia/Melbourne',
		'Pacific/Auckland',
	];

	// Redirect if not logged in
	$effect(() => {
		if (!$user) {
			goto('/auth');
		}
	});

	// Initialize form with current profile data
	$effect(() => {
		if ($profile) {
			displayName = $profile.display_name || '';
			avatarUrl = $profile.avatar_url || '';
			timezone = $profile.timezone || 'UTC';
		}
	});

	async function handleSubmit() {
		loading = true;
		errorMessage = '';
		successMessage = '';

		try {
			await updateProfile({
				display_name: displayName || null,
				avatar_url: avatarUrl || null,
				timezone: timezone || 'UTC',
			});
			successMessage = 'Profile updated successfully!';
		} catch (err) {
			errorMessage = err instanceof Error ? err.message : 'Failed to update profile';
		} finally {
			loading = false;
		}
	}
</script>

<div class="settings-container">
	<div class="settings-card">
		<div class="header">
			<h1>Profile Settings</h1>
			<button class="back-button" onclick={() => goto('/polls')}>
				← Back to Polls
			</button>
		</div>

		{#if errorMessage}
			<div class="error">{errorMessage}</div>
		{/if}

		{#if successMessage}
			<div class="success">{successMessage}</div>
		{/if}

		<form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }}>
			<div class="form-group">
				<label for="display-name">Display Name</label>
				<input
					id="display-name"
					type="text"
					bind:value={displayName}
					placeholder="Enter your display name"
					disabled={loading}
				/>
				<small class="help-text">This name will be shown to other participants</small>
			</div>

			<div class="form-group">
				<label for="avatar-url">Avatar URL</label>
				<input
					id="avatar-url"
					type="url"
					bind:value={avatarUrl}
					placeholder="https://example.com/avatar.jpg"
					disabled={loading}
				/>
				<small class="help-text">URL to your profile picture</small>
			</div>

			{#if avatarUrl}
				<div class="avatar-preview">
					<img src={avatarUrl} alt="Avatar preview" onerror={(e) => e.currentTarget.style.display = 'none'} />
				</div>
			{/if}

			<div class="form-group">
				<label for="timezone">Timezone</label>
				<select id="timezone" bind:value={timezone} disabled={loading}>
					{#each timezones as tz}
						<option value={tz}>{tz}</option>
					{/each}
				</select>
				<small class="help-text">Your local timezone for meeting scheduling</small>
			</div>

			<div class="form-actions">
				<button type="submit" class="save-button" disabled={loading}>
					{loading ? 'Saving...' : 'Save Changes'}
				</button>
			</div>
		</form>
	</div>
</div>

<style>
	.settings-container {
		display: flex;
		justify-content: center;
		align-items: center;
		min-height: 100vh;
		padding: 1rem;
		background: #f5f5f5;
	}

	.settings-card {
		background: white;
		border-radius: 12px;
		padding: 2rem;
		width: 100%;
		max-width: 600px;
		box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
	}

	.header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 1.5rem;
	}

	h1 {
		margin: 0;
		font-size: 1.75rem;
	}

	.back-button {
		padding: 0.5rem 1rem;
		background: #f5f5f5;
		border: 1px solid #ddd;
		border-radius: 6px;
		cursor: pointer;
		font-size: 0.875rem;
		transition: background 0.2s;
	}

	.back-button:hover {
		background: #e5e5e5;
	}

	.error {
		background: #fee;
		color: #c00;
		padding: 0.75rem;
		border-radius: 6px;
		margin-bottom: 1rem;
		font-size: 0.875rem;
	}

	.success {
		background: #efe;
		color: #060;
		padding: 0.75rem;
		border-radius: 6px;
		margin-bottom: 1rem;
		font-size: 0.875rem;
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 1.5rem;
	}

	.form-group {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}

	label {
		font-weight: 500;
		font-size: 0.875rem;
		color: #333;
	}

	input,
	select {
		padding: 0.75rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
		font-family: inherit;
	}

	input:focus,
	select:focus {
		outline: none;
		border-color: #007bff;
	}

	input:disabled,
	select:disabled {
		background: #f5f5f5;
		cursor: not-allowed;
	}

	.help-text {
		font-size: 0.75rem;
		color: #666;
	}

	.avatar-preview {
		display: flex;
		justify-content: center;
		margin: -0.5rem 0;
	}

	.avatar-preview img {
		width: 100px;
		height: 100px;
		border-radius: 50%;
		object-fit: cover;
		border: 2px solid #ddd;
	}

	.form-actions {
		display: flex;
		justify-content: flex-end;
		margin-top: 0.5rem;
	}

	.save-button {
		padding: 0.75rem 2rem;
		background: #007bff;
		color: white;
		border: none;
		border-radius: 6px;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s;
	}

	.save-button:hover:not(:disabled) {
		background: #0056b3;
	}

	.save-button:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}
</style>

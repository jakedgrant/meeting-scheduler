<script lang="ts">
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { user, signInWithGoogle, signInWithApple, signInWithMagicLink } from '$lib/stores/auth';

	let email = $state('');
	let loading = $state(false);
	let errorMessage = $state('');
	let successMessage = $state('');

	// Check for error in URL
	$effect(() => {
		const error = $page.url.searchParams.get('error');
		if (error) {
			errorMessage = error;
		}
	});

	// Redirect if already logged in
	$effect(() => {
		if ($user) {
			goto('/polls');
		}
	});

	async function handleGoogleSignIn() {
		loading = true;
		errorMessage = '';
		try {
			await signInWithGoogle();
		} catch (err) {
			errorMessage = err instanceof Error ? err.message : 'Failed to sign in with Google';
		} finally {
			loading = false;
		}
	}

	async function handleAppleSignIn() {
		loading = true;
		errorMessage = '';
		try {
			await signInWithApple();
		} catch (err) {
			errorMessage = err instanceof Error ? err.message : 'Failed to sign in with Apple';
		} finally {
			loading = false;
		}
	}

	async function handleMagicLink() {
		if (!email) {
			errorMessage = 'Please enter your email';
			return;
		}

		loading = true;
		errorMessage = '';
		try {
			await signInWithMagicLink(email);
			successMessage = 'Check your email for a sign-in link!';
		} catch (err) {
			errorMessage = err instanceof Error ? err.message : 'Failed to send magic link';
		} finally {
			loading = false;
		}
	}
</script>

<div class="auth-container">
	<div class="auth-card">
		<h1>Meeting Scheduler</h1>
		<p class="subtitle">Find the perfect meeting time for everyone</p>

		{#if errorMessage}
			<div class="error">{errorMessage}</div>
		{/if}

		{#if successMessage}
			<div class="success">{successMessage}</div>
		{/if}

		<div class="oauth-buttons">
			<button class="oauth-button google" onclick={handleGoogleSignIn} disabled={loading}>
				Continue with Google
			</button>
			<button class="oauth-button apple" onclick={handleAppleSignIn} disabled={loading}>
				Continue with Apple
			</button>
		</div>

		<div class="divider">
			<span>or</span>
		</div>

		<form onsubmit={(e) => { e.preventDefault(); handleMagicLink(); }}>
			<input
				type="email"
				bind:value={email}
				placeholder="Enter your email"
				disabled={loading}
			/>
			<button type="submit" class="magic-link-button" disabled={loading}>
				{loading ? 'Sending...' : 'Send Magic Link'}
			</button>
		</form>
	</div>
</div>

<style>
	.auth-container {
		display: flex;
		justify-content: center;
		align-items: center;
		min-height: 100vh;
		padding: 1rem;
		background: #f5f5f5;
	}

	.auth-card {
		background: white;
		border-radius: 12px;
		padding: 2rem;
		width: 100%;
		max-width: 400px;
		box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
	}

	h1 {
		margin: 0 0 0.5rem;
		text-align: center;
		font-size: 1.75rem;
	}

	.subtitle {
		margin: 0 0 1.5rem;
		text-align: center;
		color: #666;
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

	.oauth-buttons {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.oauth-button {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 0.5rem;
		padding: 0.75rem 1rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s;
	}

	.oauth-button:hover:not(:disabled) {
		background: #f5f5f5;
	}

	.oauth-button:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.oauth-button.google {
		background: white;
	}

	.oauth-button.apple {
		background: black;
		color: white;
		border-color: black;
	}

	.oauth-button.apple:hover:not(:disabled) {
		background: #333;
	}

	.divider {
		display: flex;
		align-items: center;
		margin: 1.5rem 0;
	}

	.divider::before,
	.divider::after {
		content: '';
		flex: 1;
		height: 1px;
		background: #ddd;
	}

	.divider span {
		padding: 0 1rem;
		color: #999;
		font-size: 0.875rem;
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	input {
		padding: 0.75rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
	}

	input:focus {
		outline: none;
		border-color: #007bff;
	}

	.magic-link-button {
		padding: 0.75rem;
		background: #007bff;
		color: white;
		border: none;
		border-radius: 6px;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s;
	}

	.magic-link-button:hover:not(:disabled) {
		background: #0056b3;
	}

	.magic-link-button:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}
</style>

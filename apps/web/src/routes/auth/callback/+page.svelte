<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { supabase } from '$lib/supabase';

	onMount(async () => {
		// Handle the OAuth callback
		const { data: { session }, error } = await supabase.auth.getSession();

		if (error) {
			console.error('Auth callback error:', error);
			goto('/auth?error=' + encodeURIComponent(error.message));
			return;
		}

		if (!session?.user) {
			console.error('No session user');
			goto('/auth?error=No%20session');
			return;
		}

		// Persist provider tokens if they exist (Google Calendar OAuth)
		if (session.provider_token || session.provider_refresh_token) {
			console.log('Found provider tokens, persisting to database...');
			console.log('provider_token present:', !!session.provider_token);
			console.log('provider_refresh_token present:', !!session.provider_refresh_token);

			// Calculate token expiry: Google access tokens typically expire in 1 hour (3600 seconds)
			// The expires_in from Google is typically 3600, so we calculate expiry as now + 3600s
			const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();

			const { error: updateError } = await supabase
				.from('profiles')
				.update({
					google_calendar_access_token: session.provider_token || null,
					google_calendar_refresh_token: session.provider_refresh_token || null,
					google_calendar_token_expires_at: expiresAt,
					calendar_integration_enabled: !!(session.provider_token || session.provider_refresh_token),
				})
				.eq('id', session.user.id);

			if (updateError) {
				console.error('Failed to persist provider tokens:', updateError);
				// Don't fail the whole auth, just log the error
			} else {
				console.log('Provider tokens persisted successfully');
			}
		}

		// Redirect to dashboard on success
		goto('/polls');
	});
</script>

<div class="callback">
	<p>Signing you in...</p>
</div>

<style>
	.callback {
		display: flex;
		justify-content: center;
		align-items: center;
		height: 100vh;
	}
</style>

<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { supabase } from '$lib/supabase';

	onMount(async () => {
		// Handle the OAuth callback
		const { error } = await supabase.auth.getSession();

		if (error) {
			console.error('Auth callback error:', error);
			goto('/auth?error=' + encodeURIComponent(error.message));
			return;
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

<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { authCallbackError } from '$lib/stores/auth';
	import { supabase } from '$lib/supabase';

	import { createAuthCallback } from '$lib/auth-callback';
	onMount(() => {
		if ($authCallbackError) return;
		const callback = createAuthCallback({ getSession: () => supabase.auth.getSession(), navigate: goto });
		void callback.run();
		return callback.dispose;
	});
</script>

<div class="callback">
	{#if $authCallbackError}
		<p role="alert">{$authCallbackError}</p>
		<a href="/polls">Return to your account</a>
	{:else}<p>Signing you in...</p>{/if}
</div>

<style>
	.callback {
		display: flex;
		justify-content: center;
		align-items: center;
		height: 100vh;
	}
</style>

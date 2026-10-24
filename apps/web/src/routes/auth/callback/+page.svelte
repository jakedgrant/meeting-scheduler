<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { supabase } from '$lib/supabase';

	import { createAuthCallback } from '$lib/auth-callback';
	onMount(() => {
		const callback = createAuthCallback({ getSession: () => supabase.auth.getSession(), navigate: goto });
		void callback.run();
		return callback.dispose;
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

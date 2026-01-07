<script lang="ts">
	import { onMount } from 'svelte';
	import { initAuth, authLoading } from '$lib/stores/auth';
	import { initCalendar, watchCalendarToken } from '$lib/stores/calendar';
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();

	onMount(async () => {
		await initAuth();
		await initCalendar();
		watchCalendarToken();
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>Meeting Scheduler</title>
</svelte:head>

{#if $authLoading}
	<div class="loading">
		<p>Loading...</p>
	</div>
{:else}
	{@render children()}
{/if}

<style>
	:global(body) {
		margin: 0;
		font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
		-webkit-font-smoothing: antialiased;
	}

	.loading {
		display: flex;
		justify-content: center;
		align-items: center;
		height: 100vh;
	}
</style>

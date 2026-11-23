<script lang="ts">
	import { onMount, onDestroy, untrack } from 'svelte';
	import { beforeNavigate } from '$app/navigation';
	import type { Poll } from '$lib/supabase';
	import { createSessionWork } from '$lib/session-scope';
	import { createPollEditDraft, hasPollEdits, pollEditChanges } from '$lib/poll-edit';
	import { updatePollDetails } from '$lib/stores/polls';

	let { poll, onClose }: { poll: Poll; onClose: () => void } = $props();
	// Keep the opening snapshot while background refreshes continue.
	const original = untrack(() => poll);
	let draft = $state(createPollEditDraft(original));
	let dialog: HTMLDialogElement;
	let saving = $state(false);
	let error = $state('');
	const work = createSessionWork();
	const dirty = $derived(hasPollEdits(original, draft));
	const validation = $derived.by(() => {
		try { pollEditChanges(original, draft); return ''; }
		catch (failure) { return failure instanceof Error ? failure.message : 'Check your poll details.'; }
	});

	function canLeave() {
		return !saving && (!dirty || confirm('Discard your poll changes?'));
	}
	function cancel() { if (canLeave()) onClose(); }
	beforeNavigate(navigation => { if (!canLeave()) navigation.cancel(); });
	onMount(() => {
		dialog.showModal();
		const protectDraft = (event: BeforeUnloadEvent) => {
			if (dirty || saving) { event.preventDefault(); event.returnValue = ''; }
		};
		window.addEventListener('beforeunload', protectDraft);
		return () => window.removeEventListener('beforeunload', protectDraft);
	});
	onDestroy(() => work.dispose());

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (saving || !dirty || validation) return;
		const isCurrent = work.capture();
		saving = true; error = '';
		try {
			await updatePollDetails(original, draft);
			if (isCurrent()) onClose();
		} catch {
			if (isCurrent()) error = 'Your changes could not be saved. Try again, or cancel and reload the poll.';
		} finally {
			if (isCurrent()) saving = false;
		}
	}
</script>

<dialog bind:this={dialog} aria-labelledby="edit-poll-title" oncancel={(event) => { event.preventDefault(); cancel(); }}>
	<form onsubmit={save}>
		<header>
			<button type="button" class="btn secondary" onclick={cancel} disabled={saving}>Cancel</button>
			<h2 id="edit-poll-title">Edit Poll</h2>
			<button type="submit" class="btn primary" disabled={saving || !dirty || !!validation}>{saving ? 'Saving…' : 'Save'}</button>
		</header>
		<fieldset disabled={saving}>
			<label for="edit-poll-name">Title</label>
			<input id="edit-poll-name" bind:value={draft.title} required />
			<label for="edit-poll-description">Description (optional)</label>
			<textarea id="edit-poll-description" bind:value={draft.description} rows="4"></textarea>
			<label for="edit-poll-location">Location (optional)</label>
			<input id="edit-poll-location" bind:value={draft.location} />
			<label class="deadline-toggle"><input type="checkbox" bind:checked={draft.hasDeadline} /> Set response deadline</label>
			{#if draft.hasDeadline}
				<label for="edit-poll-deadline">Close responses</label>
				<input id="edit-poll-deadline" type="datetime-local" bind:value={draft.deadline} required />
			{/if}
			<p>Deadline times use {original.timezone}. Editing the deadline does not reopen a closed poll.</p>
		</fieldset>
		{#if validation || error}<p class="error" role="alert">{validation || error}</p>{/if}
	</form>
</dialog>

<style>
	dialog { width: min(36rem, calc(100% - 2rem)); max-height: calc(100dvh - 2rem); box-sizing: border-box; border: 0; border-radius: 1rem; padding: 1.5rem; color: #222; }
	dialog::backdrop { background: rgb(0 0 0 / 45%); }
	header { display: flex; align-items: center; justify-content: space-between; gap: .75rem; margin-bottom: 1.5rem; }
	h2 { font-size: 1.25rem; margin: 0; }
	fieldset { border: 0; padding: 0; margin: 0; display: grid; gap: .5rem; min-width: 0; }
	label { margin-top: .75rem; font-weight: 500; }
	input:not([type='checkbox']), textarea { width: 100%; box-sizing: border-box; padding: .75rem; border: 1px solid #aaa; border-radius: .5rem; font: inherit; }
	.deadline-toggle { display: flex; align-items: center; gap: .5rem; }
	p { font-size: .875rem; color: #555; }
	.btn { padding: .5rem 1rem; border-radius: 6px; font-size: .875rem; font-weight: 500; cursor: pointer; border: 0; }
	.primary { background: #007bff; color: white; }
	.secondary { background: #f5f5f5; color: #333; }
	.btn:disabled { opacity: .6; cursor: not-allowed; }
	.error { color: #b42318; }
</style>

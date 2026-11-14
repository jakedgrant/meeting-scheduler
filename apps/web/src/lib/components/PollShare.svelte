<script lang="ts">
	import { onMount } from 'svelte';
	import { pollLink } from '$lib/poll-flow';

	let { pollId, title, shareCode }: { pollId: string; title: string; shareCode: string } = $props();

	let origin = $state('');
	let qr = $state('');
	let status = $state('');
	const link = $derived(pollLink(origin, pollId));
	const canShare = $derived(typeof navigator !== 'undefined' && typeof navigator.share === 'function');

	onMount(() => { origin = window.location.origin; });
	$effect(() => {
		if (!origin) return;
		let current = true;
		// Loaded on demand: the code is only needed once the poll exists.
		import('qrcode').then(({ default: QRCode }) => QRCode.toDataURL(link, { margin: 1, width: 320, errorCorrectionLevel: 'M' }))
			.then(url => { if (current) qr = url; })
			.catch(() => { if (current) status = 'The QR code could not be drawn. Share the link instead.'; });
		return () => { current = false; };
	});

	async function copy(text: string, what: string) {
		try {
			await navigator.clipboard.writeText(text);
			status = `${what} copied.`;
		} catch {
			status = `Copying is not available here. Select the ${what.toLowerCase()} and copy it manually.`;
		}
	}

	async function shareLink() {
		if (!canShare) { await copy(link, 'Link'); return; }
		try { await navigator.share({ title, url: link }); }
		catch (error) {
			if ((error as DOMException)?.name !== 'AbortError') await copy(link, 'Link');
		}
	}

	function download() {
		const anchor = document.createElement('a');
		anchor.href = qr;
		anchor.download = 'poll-qr-code.png';
		anchor.click();
	}

	async function shareQr() {
		try {
			const blob = await (await fetch(qr)).blob();
			const file = new File([blob], 'poll-qr-code.png', { type: 'image/png' });
			if (navigator.canShare?.({ files: [file] })) { await navigator.share({ files: [file], title }); return; }
		} catch (error) {
			if ((error as DOMException)?.name === 'AbortError') return;
		}
		download();
		status = 'QR code downloaded.';
	}
</script>

<section class="card">
	<div class="card-head">
		<h2>Share code</h2>
		<button type="button" class="text-btn" onclick={() => copy(shareCode, 'Share code')}>Copy</button>
	</div>
	<div class="code" aria-label={`Share code ${shareCode.split('').join(' ')}`} role="img">{shareCode}</div>
	<p class="note">People can enter this code to join your poll.</p>
</section>

<section class="card">
	<div class="card-head">
		<h2>Share link</h2>
		<button type="button" class="text-btn" onclick={() => copy(link, 'Link')} disabled={!origin}>Copy</button>
	</div>
	<output class="link">{link}</output>
	<button type="button" class="pill" onclick={shareLink} disabled={!origin}>Share link</button>
</section>

<section class="card">
	<h2>QR code</h2>
	{#if qr}
		<img class="qr" src={qr} alt={`QR code that opens ${title}`} width="220" height="220" />
	{:else}
		<div class="qr placeholder" aria-hidden="true"></div>
	{/if}
	<div class="row">
		<button type="button" class="pill" onclick={download} disabled={!qr}>Save image</button>
		<button type="button" class="pill" onclick={shareQr} disabled={!qr}>Share</button>
	</div>
</section>

<p class="status" role="status" aria-live="polite">{status}</p>

<style>
	.card { background: #fff; border-radius: 16px; padding: 1rem 1.25rem 1.25rem; margin-bottom: 0.75rem; display: flex; flex-direction: column; gap: 0.75rem; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1); }
	.card-head { display: flex; align-items: center; justify-content: space-between; }
	h2 { margin: 0; font-size: 1.0625rem; }
	.code { background: #e6f0fd; color: #0b4a9e; border-radius: 12px; padding: 0.75rem 0 0.75rem 0.5rem; text-align: center; font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 2rem; font-weight: 700; letter-spacing: 0.5rem; }
	.note { margin: 0; font-size: 0.8125rem; color: #5c5c61; }
	.link { background: #e6f0fd; color: #0b4a9e; border-radius: 10px; padding: 0.75rem; font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 0.875rem; overflow-wrap: anywhere; }
	.text-btn { min-height: 44px; padding: 0 0.875rem; border: 0; border-radius: 22px; background: transparent; color: #0b63ce; font: inherit; font-weight: 600; cursor: pointer; }
	.pill { flex: 1; min-height: 48px; border: 0; border-radius: 24px; background: #efeff4; color: #0b63ce; font: inherit; font-weight: 600; cursor: pointer; padding: 0 1rem; }
	.text-btn:disabled, .pill:disabled { opacity: 0.5; cursor: default; }
	.text-btn:focus-visible, .pill:focus-visible { outline: 3px solid #0b63ce; outline-offset: 2px; }
	.qr { align-self: center; width: 220px; height: 220px; border: 1px solid #e5e5ea; border-radius: 12px; padding: 8px; box-sizing: content-box; }
	.placeholder { background: #f7f7fa; }
	.row { display: flex; gap: 0.625rem; }
	.status { min-height: 1.25rem; margin: 0 0.5rem; font-size: 0.875rem; color: #333; }
</style>

<script lang="ts">
	import { offerings, purchase, loadOfferings, subscriptionLoading } from '$lib/stores/subscription';
	import { onMount } from 'svelte';
	import type { Package } from '@revenuecat/purchases-js';

	interface Props {
		onClose?: () => void;
		onSuccess?: () => void;
	}

	let { onClose, onSuccess }: Props = $props();

	let purchasing = $state(false);
	let error = $state('');
	let selectedPackage = $state<Package | null>(null);

	onMount(() => {
		loadOfferings();
	});

	function formatPrice(pkg: Package): string {
		const price = pkg.rcBillingProduct?.currentPrice;
		if (!price) return 'N/A';
		const type = String(pkg.packageType).toUpperCase();
		const period = type.includes('ANNUAL') || type.includes('YEARLY') ? 'year' : 'month';
		return `${price.formattedPrice}/${period}`;
	}

	function getPackageTitle(pkg: Package): string {
		const id = pkg.identifier.toLowerCase();
		if (id.includes('team')) return 'Team';
		if (id.includes('pro')) return 'Pro';
		return pkg.identifier;
	}

	function getPackagePeriod(pkg: Package): string {
		const type = String(pkg.packageType).toUpperCase();
		return type.includes('ANNUAL') || type.includes('YEARLY') ? 'Yearly' : 'Monthly';
	}

	function isAnnual(pkg: Package): boolean {
		const type = String(pkg.packageType).toUpperCase();
		return type.includes('ANNUAL') || type.includes('YEARLY');
	}

	async function handlePurchase() {
		if (!selectedPackage) {
			error = 'Please select a plan';
			return;
		}

		purchasing = true;
		error = '';

		try {
			const success = await purchase(selectedPackage);
			if (success) {
				onSuccess?.();
			}
		} catch (err) {
			error = err instanceof Error ? err.message : 'Purchase failed';
		} finally {
			purchasing = false;
		}
	}
</script>

<div class="paywall-overlay" onclick={onClose}>
	<div class="paywall-modal" onclick={(e) => e.stopPropagation()}>
		<button class="close-btn" onclick={onClose}>&times;</button>

		<div class="paywall-header">
			<h2>Upgrade to Pro</h2>
			<p>Unlock unlimited polls and premium features</p>
		</div>

		{#if $subscriptionLoading}
			<div class="loading">Loading plans...</div>
		{:else if $offerings.length === 0}
			<div class="no-offerings">
				<p>No subscription plans available at this time.</p>
			</div>
		{:else}
			<div class="plans">
				{#each $offerings as pkg}
					<button
						class="plan-card"
						class:selected={selectedPackage?.identifier === pkg.identifier}
						onclick={() => (selectedPackage = pkg)}
					>
						<div class="plan-header">
							<span class="plan-title">{getPackageTitle(pkg)}</span>
							<span class="plan-period">{getPackagePeriod(pkg)}</span>
						</div>
						<div class="plan-price">{formatPrice(pkg)}</div>
						{#if isAnnual(pkg)}
							<div class="plan-savings">Save 17%</div>
						{/if}
					</button>
				{/each}
			</div>

			<div class="features">
				<h3>What you get:</h3>
				<ul>
					<li>Unlimited active polls</li>
					<li>Up to 50 participants per poll</li>
					<li>Calendar integrations</li>
					<li>Priority support</li>
				</ul>
			</div>

			{#if error}
				<div class="error">{error}</div>
			{/if}

			<button
				class="purchase-btn"
				onclick={handlePurchase}
				disabled={purchasing || !selectedPackage}
			>
				{purchasing ? 'Processing...' : 'Subscribe Now'}
			</button>

			<p class="terms">
				Cancel anytime. By subscribing, you agree to our Terms of Service.
			</p>
		{/if}
	</div>
</div>

<style>
	.paywall-overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.5);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1000;
		padding: 1rem;
	}

	.paywall-modal {
		background: white;
		border-radius: 12px;
		padding: 2rem;
		max-width: 480px;
		width: 100%;
		position: relative;
		max-height: 90vh;
		overflow-y: auto;
	}

	.close-btn {
		position: absolute;
		top: 1rem;
		right: 1rem;
		background: none;
		border: none;
		font-size: 1.5rem;
		cursor: pointer;
		color: #666;
		line-height: 1;
	}

	.close-btn:hover {
		color: #333;
	}

	.paywall-header {
		text-align: center;
		margin-bottom: 1.5rem;
	}

	.paywall-header h2 {
		margin: 0 0 0.5rem;
	}

	.paywall-header p {
		margin: 0;
		color: #666;
	}

	.loading,
	.no-offerings {
		text-align: center;
		padding: 2rem;
		color: #666;
	}

	.plans {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
		gap: 1rem;
		margin-bottom: 1.5rem;
	}

	.plan-card {
		border: 2px solid #eee;
		border-radius: 8px;
		padding: 1rem;
		text-align: center;
		cursor: pointer;
		background: white;
		transition: all 0.15s;
	}

	.plan-card:hover {
		border-color: #007bff;
	}

	.plan-card.selected {
		border-color: #007bff;
		background: #f0f7ff;
	}

	.plan-header {
		margin-bottom: 0.5rem;
	}

	.plan-title {
		font-weight: 600;
		display: block;
	}

	.plan-period {
		font-size: 0.75rem;
		color: #666;
	}

	.plan-price {
		font-size: 1.25rem;
		font-weight: 600;
		color: #007bff;
	}

	.plan-savings {
		font-size: 0.75rem;
		color: #28a745;
		margin-top: 0.25rem;
	}

	.features {
		background: #f8f9fa;
		border-radius: 8px;
		padding: 1rem;
		margin-bottom: 1.5rem;
	}

	.features h3 {
		margin: 0 0 0.75rem;
		font-size: 0.875rem;
		color: #666;
	}

	.features ul {
		margin: 0;
		padding-left: 1.25rem;
	}

	.features li {
		margin-bottom: 0.5rem;
		font-size: 0.875rem;
	}

	.features li:last-child {
		margin-bottom: 0;
	}

	.error {
		background: #fee;
		color: #c00;
		padding: 0.75rem;
		border-radius: 6px;
		margin-bottom: 1rem;
		font-size: 0.875rem;
	}

	.purchase-btn {
		width: 100%;
		padding: 1rem;
		background: #007bff;
		color: white;
		border: none;
		border-radius: 8px;
		font-size: 1rem;
		font-weight: 500;
		cursor: pointer;
	}

	.purchase-btn:hover:not(:disabled) {
		background: #0056b3;
	}

	.purchase-btn:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.terms {
		text-align: center;
		font-size: 0.75rem;
		color: #999;
		margin: 1rem 0 0;
	}
</style>

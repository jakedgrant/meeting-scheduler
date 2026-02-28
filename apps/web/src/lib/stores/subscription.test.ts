import { describe, it, expect, vi } from 'vitest';

// Mock dependencies before importing
vi.mock('$app/environment', () => ({
	browser: false,
	building: false,
	dev: true
}));

vi.mock('$lib/supabase', () => ({
	supabase: {}
}));

vi.mock('$lib/revenuecat', () => ({
	getCustomerInfo: vi.fn(),
	getOfferings: vi.fn(),
	purchasePackage: vi.fn(),
	hasProAccess: vi.fn((info: any) => false),
	hasTeamAccess: vi.fn((info: any) => false)
}));

vi.mock('./auth', () => ({
	user: { subscribe: vi.fn() }
}));

import { getMaxActivePolls, getMaxParticipants } from './subscription';
import type { Subscription } from '$lib/supabase';

function createSubscription(overrides: Partial<Subscription> = {}): Subscription {
	return {
		id: 'sub-1',
		user_id: 'user-1',
		revenuecat_app_user_id: null,
		original_transaction_id: null,
		entitlement: null,
		is_active: true,
		product_id: null,
		store: null,
		period_type: null,
		purchased_at: null,
		expires_at: null,
		cancellation_at: null,
		created_at: '2025-01-01T00:00:00Z',
		updated_at: '2025-01-01T00:00:00Z',
		...overrides
	};
}

describe('getMaxActivePolls', () => {
	it('returns 1 for null subscription (free tier)', () => {
		expect(getMaxActivePolls(null)).toBe(1);
	});

	it('returns 1 for inactive subscription', () => {
		const sub = createSubscription({ is_active: false });
		expect(getMaxActivePolls(sub)).toBe(1);
	});

	it('returns Infinity for active pro_access subscription', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'pro_access' });
		expect(getMaxActivePolls(sub)).toBe(Infinity);
	});

	it('returns Infinity for active team_access subscription', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'team_access' });
		expect(getMaxActivePolls(sub)).toBe(Infinity);
	});

	it('returns 1 for active subscription with unknown entitlement', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'unknown' });
		expect(getMaxActivePolls(sub)).toBe(1);
	});

	it('returns 1 for active subscription with null entitlement', () => {
		const sub = createSubscription({ is_active: true, entitlement: null });
		expect(getMaxActivePolls(sub)).toBe(1);
	});
});

describe('getMaxParticipants', () => {
	it('returns 10 for null subscription (free tier)', () => {
		expect(getMaxParticipants(null)).toBe(10);
	});

	it('returns 10 for inactive subscription', () => {
		const sub = createSubscription({ is_active: false });
		expect(getMaxParticipants(sub)).toBe(10);
	});

	it('returns 50 for active pro_access subscription', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'pro_access' });
		expect(getMaxParticipants(sub)).toBe(50);
	});

	it('returns 100 for active team_access subscription', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'team_access' });
		expect(getMaxParticipants(sub)).toBe(100);
	});

	it('returns 10 for active subscription with unknown entitlement', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'unknown' });
		expect(getMaxParticipants(sub)).toBe(10);
	});

	it('returns 10 for active subscription with null entitlement', () => {
		const sub = createSubscription({ is_active: true, entitlement: null });
		expect(getMaxParticipants(sub)).toBe(10);
	});
});

describe('subscription tier limits integration', () => {
	it('free tier: 1 poll, 10 participants', () => {
		expect(getMaxActivePolls(null)).toBe(1);
		expect(getMaxParticipants(null)).toBe(10);
	});

	it('pro tier: unlimited polls, 50 participants', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'pro_access' });
		expect(getMaxActivePolls(sub)).toBe(Infinity);
		expect(getMaxParticipants(sub)).toBe(50);
	});

	it('team tier: unlimited polls, 100 participants', () => {
		const sub = createSubscription({ is_active: true, entitlement: 'team_access' });
		expect(getMaxActivePolls(sub)).toBe(Infinity);
		expect(getMaxParticipants(sub)).toBe(100);
	});

	it('expired subscription falls back to free tier limits', () => {
		const sub = createSubscription({
			is_active: false,
			entitlement: 'pro_access',
			expires_at: '2024-01-01T00:00:00Z'
		});
		expect(getMaxActivePolls(sub)).toBe(1);
		expect(getMaxParticipants(sub)).toBe(10);
	});
});

import { describe, it, expect, vi } from 'vitest';

// Mock $app/environment before importing the module
vi.mock('$app/environment', () => ({
	browser: false,
	building: false,
	dev: true
}));

// We need to test the pure functions: hasEntitlement, hasProAccess, hasTeamAccess
// These don't depend on browser/SDK, so we can import them directly
import { hasEntitlement, hasProAccess, hasTeamAccess } from './revenuecat';

// Create mock CustomerInfo objects for testing
function createMockCustomerInfo(activeEntitlements: string[]) {
	const active: Record<string, unknown> = {};
	for (const id of activeEntitlements) {
		active[id] = { identifier: id, isActive: true };
	}
	return {
		entitlements: { active }
	} as any;
}

describe('hasEntitlement', () => {
	it('returns false when customerInfo is null', () => {
		expect(hasEntitlement(null, 'pro_access')).toBe(false);
	});

	it('returns true when the entitlement is active', () => {
		const info = createMockCustomerInfo(['pro_access']);
		expect(hasEntitlement(info, 'pro_access')).toBe(true);
	});

	it('returns false when the entitlement is not active', () => {
		const info = createMockCustomerInfo(['pro_access']);
		expect(hasEntitlement(info, 'team_access')).toBe(false);
	});

	it('returns false when there are no active entitlements', () => {
		const info = createMockCustomerInfo([]);
		expect(hasEntitlement(info, 'pro_access')).toBe(false);
	});

	it('handles multiple active entitlements', () => {
		const info = createMockCustomerInfo(['pro_access', 'team_access']);
		expect(hasEntitlement(info, 'pro_access')).toBe(true);
		expect(hasEntitlement(info, 'team_access')).toBe(true);
	});
});

describe('hasProAccess', () => {
	it('returns false when customerInfo is null', () => {
		expect(hasProAccess(null)).toBe(false);
	});

	it('returns true when user has pro_access entitlement', () => {
		const info = createMockCustomerInfo(['pro_access']);
		expect(hasProAccess(info)).toBe(true);
	});

	it('returns true when user has team_access entitlement (includes pro)', () => {
		const info = createMockCustomerInfo(['team_access']);
		expect(hasProAccess(info)).toBe(true);
	});

	it('returns false when user has no relevant entitlements', () => {
		const info = createMockCustomerInfo(['some_other']);
		expect(hasProAccess(info)).toBe(false);
	});

	it('returns true when user has both pro and team access', () => {
		const info = createMockCustomerInfo(['pro_access', 'team_access']);
		expect(hasProAccess(info)).toBe(true);
	});
});

describe('hasTeamAccess', () => {
	it('returns false when customerInfo is null', () => {
		expect(hasTeamAccess(null)).toBe(false);
	});

	it('returns true when user has team_access entitlement', () => {
		const info = createMockCustomerInfo(['team_access']);
		expect(hasTeamAccess(info)).toBe(true);
	});

	it('returns false when user only has pro_access', () => {
		const info = createMockCustomerInfo(['pro_access']);
		expect(hasTeamAccess(info)).toBe(false);
	});

	it('returns false when user has no entitlements', () => {
		const info = createMockCustomerInfo([]);
		expect(hasTeamAccess(info)).toBe(false);
	});
});

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { get } from 'svelte/store';

vi.mock('$app/environment', () => ({
	browser: false,
	building: false,
	dev: true
}));

vi.mock('$lib/supabase', () => ({
	supabase: {
		auth: {
			getSession: vi.fn(),
			onAuthStateChange: vi.fn(),
			signInWithOAuth: vi.fn(),
			signInWithOtp: vi.fn(),
			signOut: vi.fn()
		},
		from: vi.fn()
	}
}));

vi.mock('$lib/revenuecat', () => ({
	initRevenueCat: vi.fn()
}));

import { user, session, profile, authLoading, isAuthenticated } from './auth';

describe('auth store', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		user.set(null);
		session.set(null);
		profile.set(null);
		authLoading.set(true);
	});

	describe('isAuthenticated derived store', () => {
		it('returns false when user is null', () => {
			user.set(null);
			expect(get(isAuthenticated)).toBe(false);
		});

		it('returns true when user is set', () => {
			user.set({ id: 'user-1', email: 'test@example.com' } as any);
			expect(get(isAuthenticated)).toBe(true);
		});

		it('updates reactively when user changes', () => {
			expect(get(isAuthenticated)).toBe(false);

			user.set({ id: 'user-1' } as any);
			expect(get(isAuthenticated)).toBe(true);

			user.set(null);
			expect(get(isAuthenticated)).toBe(false);
		});
	});

	describe('store initialization', () => {
		it('starts with null user', () => {
			expect(get(user)).toBeNull();
		});

		it('starts with null session', () => {
			expect(get(session)).toBeNull();
		});

		it('starts with null profile', () => {
			expect(get(profile)).toBeNull();
		});

		it('user store can be set with user data', () => {
			const userData = {
				id: 'user-1',
				email: 'test@example.com',
				app_metadata: {},
				user_metadata: {},
				aud: 'authenticated',
				created_at: '2025-01-01T00:00:00Z'
			} as any;

			user.set(userData);
			expect(get(user)).toEqual(userData);
		});

		it('profile store can be set with profile data', () => {
			const profileData = {
				id: 'user-1',
				email: 'test@example.com',
				display_name: 'Test User',
				avatar_url: null,
				timezone: 'America/New_York',
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			};

			profile.set(profileData);
			expect(get(profile)).toEqual(profileData);
			expect(get(profile)!.display_name).toBe('Test User');
		});
	});
});

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { get, writable } from 'svelte/store';

// Use vi.hoisted so the mock object is available when vi.mock factories run
const mockSupabase = vi.hoisted(() => ({
	from: vi.fn(),
	rpc: vi.fn(),
	channel: vi.fn(),
	removeChannel: vi.fn()
}));

const mockUser = vi.hoisted(() => {
	const { writable } = require('svelte/store');
	return writable(null);
});

vi.mock('$app/environment', () => ({
	browser: false,
	building: false,
	dev: true
}));

vi.mock('$lib/supabase', () => ({
	supabase: mockSupabase
}));

vi.mock('./auth', () => ({
	user: mockUser
}));

import {
	polls,
	createdPolls,
	joinedPolls,
	currentPoll,
	currentPollTimeOptions,
	currentPollParticipants,
	currentPollResponses,
	pollsLoading,
	loadParticipatedPolls,
	loadPollByCode,
	cleanupPollRealtime
} from './polls';

describe('polls store', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		// Reset stores
		polls.set([]);
		createdPolls.set([]);
		joinedPolls.set([]);
		currentPoll.set(null);
		currentPollTimeOptions.set([]);
		currentPollParticipants.set([]);
		currentPollResponses.set([]);
		pollsLoading.set(false);
		mockUser.set(null);
	});

	describe('loadParticipatedPolls', () => {
		it('clears polls when no user is authenticated', async () => {
			mockUser.set(null);
			await loadParticipatedPolls();

			expect(get(createdPolls)).toEqual([]);
			expect(get(joinedPolls)).toEqual([]);
			expect(get(polls)).toEqual([]);
		});

		it('loads created and joined polls for authenticated user', async () => {
			mockUser.set({ id: 'user-1' } as any);

			const mockCreated = [{ id: 'poll-1', title: 'My Poll' }];
			const mockJoined = [{ id: 'poll-2', title: 'Shared Poll' }];

			mockSupabase.rpc.mockResolvedValue({
				data: { created_polls: mockCreated, joined_polls: mockJoined },
				error: null
			});

			await loadParticipatedPolls();

			expect(mockSupabase.rpc).toHaveBeenCalledWith('get_user_participated_polls');
			expect(get(createdPolls)).toEqual(mockCreated);
			expect(get(joinedPolls)).toEqual(mockJoined);
			expect(get(polls)).toEqual([...mockCreated, ...mockJoined]);
		});

		it('sets pollsLoading during fetch', async () => {
			mockUser.set({ id: 'user-1' } as any);

			let loadingDuringFetch = false;
			mockSupabase.rpc.mockImplementation(async () => {
				loadingDuringFetch = get(pollsLoading);
				return { data: { created_polls: [], joined_polls: [] }, error: null };
			});

			await loadParticipatedPolls();

			expect(loadingDuringFetch).toBe(true);
			expect(get(pollsLoading)).toBe(false);
		});

		it('handles RPC error gracefully', async () => {
			mockUser.set({ id: 'user-1' } as any);

			mockSupabase.rpc.mockResolvedValue({
				data: null,
				error: { message: 'Network error' }
			});

			await loadParticipatedPolls();

			// Should not crash, polls remain empty
			expect(get(polls)).toEqual([]);
			expect(get(pollsLoading)).toBe(false);
		});

		it('handles null data fields gracefully', async () => {
			mockUser.set({ id: 'user-1' } as any);

			mockSupabase.rpc.mockResolvedValue({
				data: {},
				error: null
			});

			await loadParticipatedPolls();

			expect(get(createdPolls)).toEqual([]);
			expect(get(joinedPolls)).toEqual([]);
		});
	});

	describe('loadPollByCode', () => {
		it('calls RPC with uppercase code', async () => {
			mockSupabase.rpc.mockResolvedValue({
				data: [{ id: 'poll-1', title: 'Test', share_code: 'ABC123' }],
				error: null
			});

			const result = await loadPollByCode('abc123');

			expect(mockSupabase.rpc).toHaveBeenCalledWith('get_poll_by_code', { code: 'ABC123' });
			expect(result).toEqual({ id: 'poll-1', title: 'Test', share_code: 'ABC123' });
		});

		it('returns null when no poll found', async () => {
			mockSupabase.rpc.mockResolvedValue({
				data: [],
				error: null
			});

			const result = await loadPollByCode('NONEXIST');
			expect(result).toBeNull();
		});

		it('returns null when data is null', async () => {
			mockSupabase.rpc.mockResolvedValue({
				data: null,
				error: null
			});

			const result = await loadPollByCode('TEST');
			expect(result).toBeNull();
		});

		it('returns null on RPC error', async () => {
			mockSupabase.rpc.mockResolvedValue({
				data: null,
				error: { message: 'Error' }
			});

			const result = await loadPollByCode('TEST');
			expect(result).toBeNull();
		});
	});

	describe('cleanupPollRealtime', () => {
		it('clears all current poll stores', () => {
			currentPoll.set({ id: 'poll-1' } as any);
			currentPollTimeOptions.set([{ id: 'opt-1' } as any]);
			currentPollParticipants.set([{ id: 'part-1' } as any]);
			currentPollResponses.set([{ id: 'resp-1' } as any]);

			cleanupPollRealtime();

			expect(get(currentPoll)).toBeNull();
			expect(get(currentPollTimeOptions)).toEqual([]);
			expect(get(currentPollParticipants)).toEqual([]);
			expect(get(currentPollResponses)).toEqual([]);
		});
	});
});

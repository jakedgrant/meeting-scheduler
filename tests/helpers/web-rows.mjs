// Complete rows in the shape the database functions return, for web tests that
// replace the network client. The stores check every column of a returned row
// (apps/web/src/lib/rpc-results.ts), so each fixture row carries all of them.
// Tests pass only the fields they care about.
const stamp = '2026-10-20T00:00:00Z';
const placeholder = digit => `${digit.repeat(8)}-${digit.repeat(4)}-4${digit.repeat(3)}-8${digit.repeat(3)}-${digit.repeat(12)}`;

export const pollRow = (fields = {}) => ({
  id: placeholder('a'), creator_id: placeholder('b'), title: 'Poll', description: null, location: null,
  status: 'active', timezone: 'UTC', closes_at: null, share_code: 'TEST0001', max_participants: 10,
  is_premium: false, selected_start_time: null, selected_end_time: null, created_at: stamp, updated_at: stamp,
  ...fields
});

export const timeOptionRow = (fields = {}) => ({
  id: placeholder('c'), poll_id: placeholder('a'), start_time: '2026-11-01T12:00:00Z',
  end_time: '2026-11-01T13:00:00Z', is_all_day: false, created_at: stamp, ...fields
});

export const participantRow = (fields = {}) => ({
  id: placeholder('d'), poll_id: placeholder('a'), user_id: null, anonymous_name: null, anonymous_email: null,
  comment: null, access_token: placeholder('e'), created_at: stamp, updated_at: stamp, ...fields
});

export const responseRow = (fields = {}) => ({
  id: placeholder('f'), participant_id: placeholder('d'), time_option_id: placeholder('c'),
  status: 'available', note: null, created_at: stamp, updated_at: stamp, ...fields
});

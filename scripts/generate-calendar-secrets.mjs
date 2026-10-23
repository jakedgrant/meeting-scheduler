import { randomBytes } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// Use an exclusive, owner-readable file so keys never appear in shell history,
// process arguments, or this script's output. Fill in the Google settings locally.
const output = resolve(process.argv[2] ?? '.env.calendar.local');
const keyId = `calendar-${new Date().toISOString().slice(0, 10)}-${randomBytes(4).toString('hex')}`;
const keys = JSON.stringify({ [keyId]: randomBytes(32).toString('base64url') });
await writeFile(output, [
  '# Calendar backend secrets. Keep outside version control and retain a secure backup.',
  `CALENDAR_TOKEN_KEY_ID=${keyId}`,
  `CALENDAR_TOKEN_KEYS='${keys}'`,
  `CALENDAR_MAINTENANCE_SECRET=${randomBytes(32).toString('base64url')}`,
  'CALENDAR_GOOGLE_CLIENT_ID=',
  'CALENDAR_GOOGLE_CLIENT_SECRET=',
  'CALENDAR_ALLOWED_WEB_ORIGINS=http://localhost:5173',
  '',
].join('\n'), { flag: 'wx', mode: 0o600 });
console.log(`Created ${output}. Fill in the Google client and allowed web origins before uploading.`);

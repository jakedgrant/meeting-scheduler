const fs = require('fs');
const jwt = require('jsonwebtoken');

// Configuration
const TEAM_ID = 'PWBLH7P4Y4';
const CLIENT_ID = 'com.jacobgrant.MeetingScheduler.web'; // Services ID
// Usage: node generate-apple-secret.js [path/to/AuthKey_<KEY_ID>.p8]
// The key ID is read from the file name, so a replacement key needs no edit here.
const P8_FILE = process.argv[2] || process.env.HOME + '/Downloads/AuthKey_DFS2B52ZJD.p8';
const KEY_ID = (P8_FILE.match(/AuthKey_([A-Z0-9]{10})\.p8$/) || [])[1];
if (!KEY_ID) {
  console.error(`Expected a file named AuthKey_<KEY_ID>.p8, got ${P8_FILE}`);
  process.exit(1);
}

// Read the .p8 private key
const privateKey = fs.readFileSync(P8_FILE, 'utf8');

// Generate the secret (valid for 6 months)
const now = Math.floor(Date.now() / 1000);
const expiresIn = 6 * 30 * 24 * 60 * 60; // 6 months in seconds

const token = jwt.sign(
  {
    iss: TEAM_ID,
    iat: now,
    exp: now + expiresIn,
    aud: 'https://appleid.apple.com',
    sub: CLIENT_ID
  },
  privateKey,
  {
    algorithm: 'ES256',
    header: {
      alg: 'ES256',
      kid: KEY_ID
    }
  }
);

console.log('Apple Sign in with Apple Secret (valid for 6 months):');
console.log('');
console.log(token);
console.log('');
console.log('Copy this token and paste it into the Supabase Dashboard under:');
console.log('Authentication > Providers > Apple > Secret');

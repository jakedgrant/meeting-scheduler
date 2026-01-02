const fs = require('fs');
const jwt = require('jsonwebtoken');

// Configuration
const TEAM_ID = 'PWBLH7P4Y4';
const CLIENT_ID = 'com.jacobgrant.MeetingScheduler.web'; // Services ID
const KEY_ID = 'DFS2B52ZJD';
const P8_FILE = process.env.HOME + '/Downloads/AuthKey_DFS2B52ZJD.p8';

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

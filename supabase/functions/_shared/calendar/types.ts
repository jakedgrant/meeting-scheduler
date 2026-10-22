export class CalendarError extends Error {
  constructor(readonly code: string, readonly status: number, message: string) {
    super(message);
  }
}

export interface Identity {
  userId: string;
  sessionId: string;
}
export interface Connection {
  user_id: string;
  generation: string;
  credential_version: string;
  access_token_ciphertext: string | null;
  refresh_token_ciphertext: string | null;
  expires_at: string | null;
  provider_subject: string | null;
  provider_email: string | null;
  needs_reconnect: boolean;
}
export interface OAuthAttempt {
  state_hash: string;
  user_id: string;
  session_id: string;
  generation: string;
  verifier_ciphertext: string;
  return_to: string;
}
export interface Revocation {
  id: string;
  user_id: string;
  token_ciphertext: string;
  lease_id: string;
}
export interface TokenSet {
  accessToken: string;
  refreshToken?: string;
  expiresIn: number;
  scopes?: string[];
}
export interface TimeOption {
  id: string;
  start_time: string;
  end_time: string;
}
export interface BusyInterval {
  start: string;
  end: string;
}
export interface Provider {
  authorizationURL(state: string, challenge: string): string;
  exchange(code: string, verifier: string): Promise<TokenSet>;
  userInfo(accessToken: string): Promise<{ subject: string; email: string }>;
  refresh(refreshToken: string): Promise<TokenSet>;
  freeBusy(
    accessToken: string,
    start: string,
    end: string,
  ): Promise<BusyInterval[]>;
  revoke(refreshToken: string): Promise<void>;
}

// A deliberately finite service-role-only SQL API. No client can invoke it.
export type Operation =
  | "session"
  | "read"
  | "pending_revocation"
  | "begin"
  | "consume"
  | "connect"
  | "refresh"
  | "rewrap"
  | "invalidate"
  | "disconnect"
  | "finish_callback"
  | "claim_revocations"
  | "finish_revocation"
  | "rotation_candidates";
export interface Repository {
  call<T>(
    action: Operation,
    userId?: string,
    data?: Record<string, unknown>,
  ): Promise<T>;
}
export interface CalendarConfig {
  webOrigins: string[];
  mobileReturnURL: string;
}

export const tokenPurpose = (userId: string, kind: "access" | "refresh") =>
  `${userId}:${kind}`;
export const verifierPurpose = (userId: string, hash: string) =>
  `${userId}:oauth:${hash}`;

export function connected(
  connection: Connection | null,
): connection is Connection {
  return !!connection?.refresh_token_ciphertext &&
    !!connection.access_token_ciphertext && !connection.needs_reconnect;
}

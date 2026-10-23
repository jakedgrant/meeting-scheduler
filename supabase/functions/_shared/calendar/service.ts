import { pkceChallenge, randomSecret, sha256, TokenCipher } from "./crypto.ts";
import { CALENDAR_SCOPE } from "./google.ts";
import {
  type CalendarConfig,
  CalendarError,
  connected,
  type Connection,
  type Identity,
  type OAuthAttempt,
  type Provider,
  type Repository,
  type Revocation,
  type TimeOption,
  tokenPurpose,
  verifierPurpose,
} from "./types.ts";

export class CalendarService {
  constructor(
    private repository: Repository,
    private provider: Provider,
    private cipher: TokenCipher,
    private config: CalendarConfig,
    private now: () => number = Date.now,
  ) {}

  async status(identity: Identity) {
    const connection = await this.repository.call<Connection | null>(
      "read",
      identity.userId,
    );
    const pending = await this.repository.call<boolean>(
      "pending_revocation",
      identity.userId,
    );
    return {
      connected: connected(connection),
      accountEmail: connection?.provider_email ?? null,
      requiresReconnect: connection?.needs_reconnect ?? false,
      revocationPending: pending,
    };
  }

  async start(
    identity: Identity,
    target: unknown,
    origin: unknown,
  ): Promise<{ authorizationURL: string }> {
    let returnTo: string;
    if (
      target === "web" && typeof origin === "string" &&
      this.config.webOrigins.includes(origin)
    ) {
      returnTo = origin + "/settings";
    } else if (
      (target === "ios" || target === "android") && origin === undefined
    ) {
      returnTo = this.config.mobileReturnURL;
    } else {
      throw new CalendarError(
        "invalid_return_target",
        400,
        "Unsupported calendar return location.",
      );
    }
    // Reconnect must retire the previous grant, including a failed/expired one.
    // Never overwrite a refresh token and lose the ability to revoke it.
    const previous = await this.repository.call<Connection | null>(
      "read",
      identity.userId,
    );
    if (previous?.refresh_token_ciphertext) {
      await this.repository.call("disconnect", identity.userId);
    }
    // A deferred revocation must finish before a new consent grant is created.
    await this.revokePending(identity.userId);
    if (
      await this.repository.call<boolean>("pending_revocation", identity.userId)
    ) {
      throw new CalendarError(
        "revocation_pending",
        409,
        "Disconnect is still being completed. Try again shortly.",
      );
    }
    const state = randomSecret();
    const verifier = randomSecret();
    const stateHash = await sha256(state);
    await this.repository.call("begin", identity.userId, {
      session_id: identity.sessionId,
      state_hash: stateHash,
      verifier_ciphertext: await this.cipher.encrypt(
        verifier,
        verifierPurpose(identity.userId, stateHash),
      ),
      return_to: returnTo,
    });
    return {
      authorizationURL: this.provider.authorizationURL(
        state,
        await pkceChallenge(verifier),
      ),
    };
  }

  async callback(parameters: URLSearchParams): Promise<string> {
    const state = parameters.get("state");
    if (
      !state || !/^[A-Za-z0-9_-]{43}$/.test(state) ||
      parameters.getAll("state").length !== 1
    ) {
      throw new CalendarError(
        "invalid_oauth_state",
        400,
        "Calendar authorization expired. Start again from Settings.",
      );
    }
    const stateHash = await sha256(state);
    const attempt = await this.repository.call<OAuthAttempt | null>(
      "consume",
      undefined,
      { state_hash: stateHash },
    );
    if (!attempt) {
      throw new CalendarError(
        "invalid_oauth_state",
        400,
        "Calendar authorization expired. Start again from Settings.",
      );
    }
    // return_to was constructed from a server allowlist, never from callback input.
    const returnURL = new URL(attempt.return_to);
    if (
      attempt.return_to !== this.config.mobileReturnURL &&
      !(this.config.webOrigins.includes(returnURL.origin) &&
        returnURL.pathname === "/settings" &&
        !returnURL.search && !returnURL.hash && !returnURL.username &&
        !returnURL.password)
    ) {
      throw new CalendarError(
        "invalid_return_target",
        400,
        "Calendar return location is no longer allowed.",
      );
    }
    let result = "failed";
    let cleanupToken: string | undefined;
    try {
      if (parameters.has("error")) {
        result = parameters.get("error") === "access_denied"
          ? "cancelled"
          : "failed";
      } else {
        const code = parameters.get("code");
        if (
          !code || code.length > 16000 || parameters.getAll("code").length !== 1
        ) {
          throw new CalendarError(
            "invalid_oauth_code",
            400,
            "Calendar authorization failed.",
          );
        }
        const verifier = await this.cipher.decrypt(
          attempt.verifier_ciphertext,
          verifierPurpose(attempt.user_id, stateHash),
        );
        const tokens = await this.provider.exchange(code, verifier);
        cleanupToken = tokens.refreshToken ?? tokens.accessToken;
        if (!tokens.refreshToken || !tokens.scopes?.includes(CALENDAR_SCOPE)) {
          throw new CalendarError(
            "calendar_permission_missing",
            409,
            "Grant calendar permission and reconnect.",
          );
        }
        const account = await this.provider.userInfo(tokens.accessToken);
        const saved = await this.repository.call<boolean>(
          "connect",
          attempt.user_id,
          {
            generation: attempt.generation,
            state_hash: stateHash,
            session_id: attempt.session_id,
            access_token_ciphertext: await this.cipher.encrypt(
              tokens.accessToken,
              tokenPurpose(attempt.user_id, "access"),
            ),
            refresh_token_ciphertext: await this.cipher.encrypt(
              tokens.refreshToken,
              tokenPurpose(attempt.user_id, "refresh"),
            ),
            expires_at: new Date(this.now() + tokens.expiresIn * 1000)
              .toISOString(),
            provider_subject: account.subject,
            provider_email: account.email,
          },
        );
        if (saved) {
          cleanupToken = undefined;
          result = "connected";
        }
      }
    } catch (error) {
      // Error codes only: provider responses and database errors can contain secrets.
      console.warn(
        "calendar_oauth_failed",
        error instanceof CalendarError ? error.code : "internal_error",
      );
    }
    if (result !== "connected") {
      try {
        await this.repository.call("finish_callback", attempt.user_id, {
          state_hash: stateHash,
          ...(cleanupToken
            ? {
              token_ciphertext: await this.cipher.encrypt(
                cleanupToken,
                tokenPurpose(attempt.user_id, "refresh"),
              ),
            }
            : {}),
        });
        if (cleanupToken) await this.revokePending(attempt.user_id);
      } catch {
        // If durable storage is down, also try to revoke the newly issued token.
        // This does not turn a failed authorization into a successful connection.
        if (cleanupToken) {
          try {
            await this.provider.revoke(cleanupToken);
          } catch {
            console.error("calendar_oauth_cleanup_required");
          }
        }
      }
    }
    returnURL.searchParams.set("calendar", result);
    return returnURL.toString();
  }

  async disconnect(identity: Identity) {
    await this.repository.call("disconnect", identity.userId);
    await this.revokePending(identity.userId);
    return this.status(identity);
  }

  async revokePending(userId?: string): Promise<number> {
    const jobs = await this.repository.call<Revocation[]>(
      "claim_revocations",
      userId,
    );
    const results = await Promise.all(jobs.map(async (job) => {
      let success = false;
      try {
        await this.provider.revoke(
          await this.cipher.decrypt(
            job.token_ciphertext,
            tokenPurpose(job.user_id, "refresh"),
          ),
        );
        success = true;
      } catch {
        console.warn("calendar_revocation_retry");
      }
      await this.repository.call("finish_revocation", undefined, {
        id: job.id,
        lease_id: job.lease_id,
        success,
      });
      return success ? 1 : 0;
    }));
    return results.reduce<number>((sum, result) => sum + result, 0);
  }

  async rotateKeys(): Promise<number> {
    const records = await this.repository.call<Connection[]>(
      "rotation_candidates",
      undefined,
      { key_id: this.cipher.activeKeyId },
    );
    let rotated = 0;
    for (const record of records) {
      const saved = await this.repository.call<boolean>(
        "rewrap",
        record.user_id,
        {
          generation: record.generation,
          credential_version: record.credential_version,
          access_token_ciphertext: await this.cipher.encrypt(
            await this.cipher.decrypt(
              record.access_token_ciphertext!,
              tokenPurpose(record.user_id, "access"),
            ),
            tokenPurpose(record.user_id, "access"),
          ),
          refresh_token_ciphertext: await this.cipher.encrypt(
            await this.cipher.decrypt(
              record.refresh_token_ciphertext!,
              tokenPurpose(record.user_id, "refresh"),
            ),
            tokenPurpose(record.user_id, "refresh"),
          ),
        },
      );
      if (saved) rotated++;
    }
    return rotated;
  }

  private async access(
    userId: string,
    forceRefresh = false,
  ): Promise<{ token: string; connection: Connection }> {
    const record = await this.repository.call<Connection | null>(
      "read",
      userId,
    );
    if (!connected(record)) {
      throw new CalendarError(
        "reconnect_required",
        409,
        "Connect Google Calendar in Settings.",
      );
    }
    if (!forceRefresh && Date.parse(record.expires_at!) > this.now() + 60000) {
      return {
        token: await this.cipher.decrypt(
          record.access_token_ciphertext!,
          tokenPurpose(userId, "access"),
        ),
        connection: record,
      };
    }
    try {
      const refreshToken = await this.cipher.decrypt(
        record.refresh_token_ciphertext!,
        tokenPurpose(userId, "refresh"),
      );
      const tokens = await this.provider.refresh(refreshToken);
      if (tokens.scopes && !tokens.scopes.includes(CALENDAR_SCOPE)) {
        throw new CalendarError(
          "reconnect_required",
          409,
          "Reconnect Google Calendar.",
        );
      }
      const saved = await this.repository.call<boolean>("refresh", userId, {
        generation: record.generation,
        credential_version: record.credential_version,
        access_token_ciphertext: await this.cipher.encrypt(
          tokens.accessToken,
          tokenPurpose(userId, "access"),
        ),
        refresh_token_ciphertext: await this.cipher.encrypt(
          tokens.refreshToken ?? refreshToken,
          tokenPurpose(userId, "refresh"),
        ),
        expires_at: new Date(this.now() + tokens.expiresIn * 1000)
          .toISOString(),
      });
      if (!saved) {
        throw new CalendarError(
          "connection_changed",
          409,
          "Calendar connection changed. Try again.",
        );
      }
      // Re-read the CAS version so disconnect/reauthorization can fence this request.
      const current = await this.repository.call<Connection | null>(
        "read",
        userId,
      );
      if (!connected(current) || current.generation !== record.generation) {
        throw new CalendarError(
          "connection_changed",
          409,
          "Calendar connection changed. Try again.",
        );
      }
      return {
        token: await this.cipher.decrypt(
          current.access_token_ciphertext!,
          tokenPurpose(userId, "access"),
        ),
        connection: current,
      };
    } catch (error) {
      if (
        error instanceof CalendarError && error.code === "reconnect_required"
      ) {
        await this.repository.call("invalidate", userId, {
          generation: record.generation,
          credential_version: record.credential_version,
        });
      }
      throw error;
    }
  }

  async conflicts(identity: Identity, options: TimeOption[]) {
    const start = new Date(
      Math.min(...options.map((option) => Date.parse(option.start_time))),
    ).toISOString();
    const end = new Date(
      Math.max(...options.map((option) => Date.parse(option.end_time))),
    ).toISOString();
    let access = await this.access(identity.userId);
    let busy;
    try {
      busy = await this.provider.freeBusy(access.token, start, end);
    } catch (error) {
      if (
        !(error instanceof CalendarError) ||
        error.code !== "provider_unauthorized"
      ) throw error;
      access = await this.access(identity.userId, true);
      try {
        busy = await this.provider.freeBusy(access.token, start, end);
      } catch (retryError) {
        if (
          retryError instanceof CalendarError &&
          retryError.code === "provider_unauthorized"
        ) {
          await this.repository.call("invalidate", identity.userId, {
            generation: access.connection.generation,
            credential_version: access.connection.credential_version,
          });
        }
        throw retryError;
      }
    }
    const current = await this.repository.call<Connection | null>(
      "read",
      identity.userId,
    );
    const sessionActive = await this.repository.call<boolean>(
      "session",
      identity.userId,
      { session_id: identity.sessionId },
    );
    if (
      !sessionActive || !connected(current) ||
      current.generation !== access.connection.generation
    ) {
      throw new CalendarError(
        "connection_changed",
        409,
        "Calendar connection changed. Try again.",
      );
    }
    return {
      success: true,
      coverage: "primary",
      conflictingIds: options.filter((option) =>
        busy.some((interval) =>
          Date.parse(interval.start) < Date.parse(option.end_time) &&
          Date.parse(interval.end) > Date.parse(option.start_time)
        )
      )
        .map((option) => option.id),
    };
  }
}

export function parseOptions(value: unknown): TimeOption[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 200) {
    throw new CalendarError(
      "invalid_options",
      400,
      "Provide between 1 and 200 time options.",
    );
  }
  const ids = new Set<string>();
  const options = value.map((option) => {
    if (
      !option || typeof option.id !== "string" || option.id.length > 128 ||
      !option.id || ids.has(option.id) ||
      typeof option.start_time !== "string" ||
      typeof option.end_time !== "string" ||
      !/^\d{4}-\d\d-\d\dT.+(?:Z|[+-]\d\d:\d\d)$/.test(option.start_time) ||
      !/^\d{4}-\d\d-\d\dT.+(?:Z|[+-]\d\d:\d\d)$/.test(option.end_time)
    ) {
      throw new CalendarError(
        "invalid_options",
        400,
        "Time options must have unique IDs and zoned timestamps.",
      );
    }
    const start = Date.parse(option.start_time),
      end = Date.parse(option.end_time);
    if (
      !Number.isFinite(start) || !Number.isFinite(end) || end <= start ||
      end - start > 7 * 86400000
    ) {
      throw new CalendarError(
        "invalid_options",
        400,
        "Time option ranges must be valid and at most seven days.",
      );
    }
    ids.add(option.id);
    return {
      id: option.id,
      start_time: option.start_time,
      end_time: option.end_time,
    };
  });
  const dates = options.flatMap(
    (option) => [Date.parse(option.start_time), Date.parse(option.end_time)],
  );
  if (Math.max(...dates) - Math.min(...dates) > 93 * 86400000) {
    throw new CalendarError(
      "invalid_options",
      400,
      "Calendar checks can cover at most 93 days.",
    );
  }
  return options;
}

import { base64url, pkceChallenge, sha256, TokenCipher } from "./crypto.ts";
import { CALENDAR_SCOPE, GoogleCalendarProvider } from "./google.ts";
import { calendarHandler } from "./http.ts";
import { authenticateCalendar } from "./identity.ts";
import { CalendarService, parseOptions } from "./service.ts";
import {
  CalendarError,
  type Connection,
  type Identity,
  type OAuthAttempt,
  type Operation,
  type Provider,
  type Repository,
  type Revocation,
  tokenPurpose,
  type TokenSet,
} from "./types.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${JSON.stringify(actual)} != ${JSON.stringify(expected)}`,
  );
}
async function rejects(action: () => unknown, code?: string) {
  try {
    await action();
  } catch (error) {
    if (code) {
      assert(
        error instanceof CalendarError && error.code === code,
        `Expected ${code}`,
      );
    }
    return;
  }
  throw new Error("Expected rejection");
}

const userId = "00000000-0000-4000-8000-000000000001";
const otherId = "00000000-0000-4000-8000-000000000002";
const sessionId = "00000000-0000-4000-8000-000000000003";
const identity: Identity = { userId, sessionId };
const issuer = "https://project.example.test/auth/v1";
const key = base64url(new Uint8Array(32).fill(7));
const nextKey = base64url(new Uint8Array(32).fill(8));
const tokens: TokenSet = {
  accessToken: "google-access-secret",
  refreshToken: "google-refresh-secret",
  expiresIn: 3600,
  scopes: [CALENDAR_SCOPE],
};
const slot = {
  id: "slot",
  start_time: "2026-11-02T15:00:00Z",
  end_time: "2026-11-02T16:00:00Z",
};

// This test adapter models the repository contract; SQL permission, transaction,
// session and fencing semantics are tested separately against Postgres/PGlite.
class MemoryRepository implements Repository {
  rows = new Map<string, Connection>();
  attempts = new Map<string, OAuthAttempt & { consumed?: boolean }>();
  jobs: Revocation[] = [];
  activeSession = true;
  calls: {
    action: Operation;
    userId?: string;
    data: Record<string, unknown>;
  }[] = [];
  call<T>(
    action: Operation,
    id?: string,
    data: Record<string, unknown> = {},
  ): Promise<T> {
    this.calls.push({ action, userId: id, data });
    let result: unknown = null;
    const row = id ? this.rows.get(id) : undefined;
    switch (action) {
      case "session":
        result = this.activeSession && id === userId &&
          data.session_id === sessionId;
        break;
      case "read":
        result = row ? structuredClone(row) : null;
        break;
      case "pending_revocation":
        result = this.jobs.some((job) => job.user_id === id);
        break;
      case "begin": {
        if (
          row?.refresh_token_ciphertext || [...this.attempts.values()].some(
            (attempt) => attempt.user_id === id && attempt.consumed,
          )
        ) {
          throw new CalendarError(
            "calendar_operation_pending",
            409,
            "Calendar operation pending.",
          );
        }
        const connection: Connection = row ??
          {
            user_id: id!,
            generation: "",
            credential_version: crypto.randomUUID(),
            access_token_ciphertext: null,
            refresh_token_ciphertext: null,
            expires_at: null,
            provider_subject: null,
            provider_email: null,
            needs_reconnect: false,
          };
        connection.generation = crypto.randomUUID();
        this.rows.set(id!, connection);
        for (const [hash, attempt] of this.attempts) {
          if (attempt.user_id === id) this.attempts.delete(hash);
        }
        this.attempts.set(data.state_hash as string, {
          state_hash: data.state_hash as string,
          user_id: id!,
          generation: connection.generation,
          session_id: data.session_id as string,
          verifier_ciphertext: data.verifier_ciphertext as string,
          return_to: data.return_to as string,
        });
        result = connection.generation;
        break;
      }
      case "consume": {
        const attempt = this.attempts.get(data.state_hash as string);
        if (this.activeSession && attempt && !attempt.consumed) {
          attempt.consumed = true;
          result = structuredClone(attempt);
        }
        break;
      }
      case "connect":
      case "refresh":
      case "rewrap": {
        result = !!row && row.generation === data.generation &&
          (action === "connect"
            ? this.activeSession &&
              !!this.attempts.get(data.state_hash as string)?.consumed &&
              !this.jobs.some((job) => job.user_id === id)
            : row.credential_version === data.credential_version) &&
          (action === "connect" || !!row.refresh_token_ciphertext);
        if (result && row) {
          row.access_token_ciphertext = data.access_token_ciphertext as string;
          row.refresh_token_ciphertext = data
            .refresh_token_ciphertext as string;
          row.credential_version = crypto.randomUUID();
          if (typeof data.expires_at === "string") {
            row.expires_at = data.expires_at;
          }
          if (action === "connect") {
            this.attempts.delete(data.state_hash as string);
            row.needs_reconnect = false;
            row.provider_subject = data.provider_subject as string;
            row.provider_email = data.provider_email as string;
          }
        }
        break;
      }
      case "invalidate":
        if (
          row && row.generation === data.generation &&
          row.credential_version === data.credential_version
        ) row.needs_reconnect = true;
        break;
      case "disconnect":
        if (row) {
          if (row.refresh_token_ciphertext) {
            this.enqueue(id!, row.refresh_token_ciphertext);
          }
          row.generation = crypto.randomUUID();
          row.access_token_ciphertext = null;
          row.refresh_token_ciphertext = null;
          row.expires_at = null;
          row.provider_email = null;
          row.needs_reconnect = false;
        }
        for (const [hash, attempt] of this.attempts) {
          if (attempt.user_id === id && !attempt.consumed) {
            this.attempts.delete(hash);
          }
        }
        break;
      case "finish_callback":
        if (data.token_ciphertext) {
          this.enqueue(id!, data.token_ciphertext as string);
        }
        this.attempts.delete(data.state_hash as string);
        break;
      case "claim_revocations":
        result = this.jobs.filter((job) =>
          (!id || job.user_id === id) && !job.lease_id
        ).slice(0, 20)
          .map((job) => {
            job.lease_id = crypto.randomUUID();
            return { ...job };
          });
        break;
      case "finish_revocation": {
        const index = this.jobs.findIndex((job) =>
          job.id === data.id && job.lease_id === data.lease_id
        );
        if (index >= 0) {
          if (data.success) this.jobs.splice(index, 1);
          else this.jobs[index].lease_id = "";
        }
        break;
      }
      case "rotation_candidates":
        result = [...this.rows.values()].filter((record) =>
          record.refresh_token_ciphertext &&
          JSON.parse(record.refresh_token_ciphertext).key_id !== data.key_id
        ).map((record) => ({ ...record }));
        break;
    }
    return Promise.resolve(result as T);
  }
  private enqueue(id: string, ciphertext: string) {
    this.jobs.push({
      id: crypto.randomUUID(),
      user_id: id,
      token_ciphertext: ciphertext,
      lease_id: "",
    });
  }
}

class TestProvider implements Provider {
  exchangeHook?: () => Promise<TokenSet>;
  refreshHook?: () => Promise<TokenSet>;
  busyHook?: () => Promise<{ start: string; end: string }[]>;
  revokeFails = false;
  exchanges: { code: string; verifier: string }[] = [];
  refreshes: string[] = [];
  revoked: string[] = [];
  authorizationURL(state: string, challenge: string) {
    return `https://accounts.google.com/o/oauth2/v2/auth?state=${state}&code_challenge=${challenge}`;
  }
  async exchange(code: string, verifier: string) {
    this.exchanges.push({ code, verifier });
    return this.exchangeHook ? await this.exchangeHook() : { ...tokens };
  }
  userInfo() {
    return Promise.resolve({
      subject: "google-subject",
      email: "calendar@example.test",
    });
  }
  async refresh(value: string) {
    this.refreshes.push(value);
    return this.refreshHook ? await this.refreshHook() : { ...tokens };
  }
  async freeBusy() {
    return this.busyHook
      ? await this.busyHook()
      : [{ start: slot.start_time, end: slot.end_time }];
  }
  revoke(value: string) {
    if (this.revokeFails) return Promise.reject(new Error("provider outage"));
    this.revoked.push(value);
    return Promise.resolve();
  }
}

async function fixture(cipher?: TokenCipher) {
  cipher ??= await TokenCipher.create("key1", { key1: key });
  const repository = new MemoryRepository();
  const provider = new TestProvider();
  const service = new CalendarService(repository, provider, cipher, {
    webOrigins: ["https://web.example.test"],
    mobileReturnURL: "meetingscheduler://calendar/callback",
  });
  const verified = (token: string) =>
    Promise.resolve(
      token === "verified-test-token"
        ? {
          sub: userId,
          session_id: sessionId,
          iss: issuer,
          aud: "authenticated",
          role: "authenticated",
          exp: Date.now() / 1000 + 3600,
        }
        : null,
    );
  const handlers = (
    kind: "connection" | "conflicts" | "callback" | "maintenance",
  ) =>
    calendarHandler(kind, {
      service,
      webOrigins: ["https://web.example.test"],
      authenticate: (request) =>
        authenticateCalendar(request, verified, repository, issuer),
      authorizeMaintenance: (request) => {
        if (
          request.headers.get("Authorization") !== "Bearer maintenance-only"
        ) {
          throw new CalendarError(
            "authentication_required",
            401,
            "Authentication required.",
          );
        }
        return Promise.resolve();
      },
    });
  const connect = async () => {
    const start = await service.start(
      identity,
      "web",
      "https://web.example.test",
    );
    const state = new URL(start.authorizationURL).searchParams.get("state")!;
    const result = await service.callback(
      new URLSearchParams({ state, code: "server-only-code" }),
    );
    assert(result.includes("calendar=connected"));
  };
  return { repository, provider, service, cipher, handlers, connect };
}

function request(
  body: unknown,
  token = "verified-test-token",
  extra: Record<string, string> = {},
) {
  return new Request("https://project.example.test/function", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
      ...extra,
    },
    body: JSON.stringify(body),
  });
}

Deno.test("AES-GCM is randomized and binds encrypted credentials to owner and purpose", async () => {
  const cipher = await TokenCipher.create("key1", { key1: key });
  const value = await cipher.encrypt(
    "provider-refresh-secret",
    tokenPurpose(userId, "refresh"),
  );
  assert(!value.includes("provider-refresh-secret"));
  assert(
    value !==
      await cipher.encrypt(
        "provider-refresh-secret",
        tokenPurpose(userId, "refresh"),
      ),
  );
  equal(
    await cipher.decrypt(value, tokenPurpose(userId, "refresh")),
    "provider-refresh-secret",
  );
  await rejects(() => cipher.decrypt(value, tokenPurpose(otherId, "refresh")));
  await rejects(() => cipher.decrypt(value, tokenPurpose(userId, "access")));
  const tampered = JSON.parse(value);
  tampered.ciphertext = (tampered.ciphertext[0] === "A" ? "B" : "A") +
    tampered.ciphertext.slice(1);
  await rejects(() =>
    cipher.decrypt(JSON.stringify(tampered), tokenPurpose(userId, "refresh"))
  );
});

Deno.test("versioned key ring reads retired keys and encrypts with the active key", async () => {
  const old = await TokenCipher.create("old", { old: key });
  const value = await old.encrypt("secret", "purpose");
  const next = await TokenCipher.create("next", { old: key, next: nextKey });
  equal(await next.decrypt(value, "purpose"), "secret");
  equal(JSON.parse(await next.encrypt("secret", "purpose")).key_id, "next");
  await rejects(() => TokenCipher.create("next", { old: key }));
  await rejects(() => TokenCipher.create("short", { short: "YQ" }));
  await rejects(() =>
    next.decrypt(
      JSON.stringify({ ...JSON.parse(value), version: 2 }),
      "purpose",
    )
  );
});

Deno.test("PKCE implements the RFC 7636 S256 test vector", async () => {
  equal(
    await pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  );
});

Deno.test("identity rejects forged tokens and caller-supplied x-user-id without touching privileged storage", async () => {
  const f = await fixture();
  const forged = await f.handlers("connection")(
    request({ action: "status" }, "forged-token"),
  );
  equal(forged.status, 401);
  const headerOnly = await f.handlers("connection")(
    new Request("https://project.example.test/function", {
      method: "POST",
      headers: { "x-user-id": otherId, "Content-Type": "application/json" },
      body: '{"action":"status"}',
    }),
  );
  equal(headerOnly.status, 401);
  equal(f.repository.calls.length, 0);
});

Deno.test("verified claims still require issuer, audience, role, expiry, session and a non-anonymous user", async () => {
  const repository = new MemoryRepository();
  const valid = {
    sub: userId,
    session_id: sessionId,
    iss: issuer,
    aud: "authenticated",
    role: "authenticated",
    exp: Date.now() / 1000 + 3600,
  };
  for (
    const change of [
      { iss: "https://wrong.test" },
      { aud: "wrong" },
      { role: "service_role" },
      { exp: 1 },
      { exp: undefined },
      { session_id: undefined },
      { is_anonymous: true },
    ]
  ) {
    await rejects(
      () =>
        authenticateCalendar(
          request({}),
          () => Promise.resolve({ ...valid, ...change }),
          repository,
          issuer,
        ),
      "authentication_required",
    );
  }
  repository.activeSession = false;
  await rejects(
    () =>
      authenticateCalendar(
        request({}),
        () => Promise.resolve(valid),
        repository,
        issuer,
      ),
    "authentication_required",
  );
});

Deno.test("status response contains metadata only and cannot be redirected to another user", async () => {
  const f = await fixture();
  await f.connect();
  const result = await f.handlers("connection")(request({ action: "status" }));
  equal(result.status, 200);
  const text = await result.text();
  assert(
    !/secret|ciphertext|google-subject|access_token|refresh_token/.test(text),
  );
  equal(JSON.parse(text), {
    connected: true,
    accountEmail: "calendar@example.test",
    requiresReconnect: false,
    revocationPending: false,
  });
  equal(
    (await f.handlers("connection")(
      request({ action: "status", user_id: otherId }),
    )).status,
    400,
  );
  equal(
    (await f.handlers("connection")(
      request({
        action: "start",
        target: "web",
        origin: "https://evil.example",
      }),
    )).status,
    400,
  );
  equal(
    (await f.handlers("connection")(
      request({ action: "connect", refresh_token: "client-token" }),
    )).status,
    400,
  );
});

Deno.test("OAuth state stores only a hash and encrypted PKCE verifier, then callback stores only encrypted tokens", async () => {
  const f = await fixture();
  const result = await f.service.start(
    identity,
    "web",
    "https://web.example.test",
  );
  const url = new URL(result.authorizationURL),
    state = url.searchParams.get("state")!;
  assert(state.length === 43);
  const attempt = f.repository.attempts.get(await sha256(state))!;
  assert(attempt && !JSON.stringify(attempt).includes(state));
  const callback = new URLSearchParams({
    state,
    code: "authorization-code",
    redirect_to: "https://evil.example",
  });
  equal(
    await f.service.callback(callback),
    "https://web.example.test/settings?calendar=connected",
  );
  equal(
    await pkceChallenge(f.provider.exchanges[0].verifier),
    url.searchParams.get("code_challenge"),
  );
  const stored = f.repository.rows.get(userId)!;
  assert(!JSON.stringify(stored).includes(tokens.accessToken));
  assert(!JSON.stringify(stored).includes(tokens.refreshToken!));
  await rejects(() => f.service.callback(callback), "invalid_oauth_state");
});

Deno.test("cancelled OAuth leaves no connection and never reflects provider errors into redirects", async () => {
  const f = await fixture();
  const start = await f.service.start(identity, "ios", undefined);
  const state = new URL(start.authorizationURL).searchParams.get("state")!;
  equal(
    await f.service.callback(
      new URLSearchParams({
        state,
        error: "access_denied",
        error_description: "sensitive-provider-detail",
      }),
    ),
    "meetingscheduler://calendar/callback?calendar=cancelled",
  );
  equal((await f.service.status(identity)).connected, false);
});

Deno.test("a callback issued before disconnect cannot reconnect the account", async () => {
  const f = await fixture();
  const start = await f.service.start(identity, "android", undefined);
  await f.service.disconnect(identity);
  await rejects(
    () =>
      f.service.callback(
        new URLSearchParams({
          state: new URL(start.authorizationURL).searchParams.get("state")!,
          code: "old-code",
        }),
      ),
    "invalid_oauth_state",
  );
  equal((await f.service.status(identity)).connected, false);
});

Deno.test("an exchanging callback blocks reconnect until its failed grant is cleaned up", async () => {
  const f = await fixture();
  const start = await f.service.start(
    identity,
    "web",
    "https://web.example.test",
  );
  let finish!: (value: TokenSet) => void;
  let signal!: () => void;
  const exchanged = new Promise<void>((resolve) => {
    signal = resolve;
  });
  f.provider.exchangeHook = () => {
    signal();
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const pending = f.service.callback(
    new URLSearchParams({
      state: new URL(start.authorizationURL).searchParams.get("state")!,
      code: "old-code",
    }),
  );
  await exchanged;
  await f.service.disconnect(identity);
  await rejects(
    () => f.service.start(identity, "ios", undefined),
    "calendar_operation_pending",
  );
  finish(tokens);
  assert((await pending).includes("calendar=failed"));
  equal(f.provider.revoked, [tokens.refreshToken]);
  equal(f.repository.attempts.size, 0);
  f.provider.exchangeHook = undefined;
  await f.connect();
  equal((await f.service.status(identity)).connected, true);
});

Deno.test("reconnect revokes a retained grant before requesting another consent", async () => {
  const f = await fixture();
  await f.connect();
  f.repository.rows.get(userId)!.needs_reconnect = true;
  await f.service.start(identity, "ios", undefined);
  equal(f.provider.revoked, [tokens.refreshToken]);
  equal(f.repository.rows.get(userId)!.refresh_token_ciphertext, null);
});

Deno.test("disconnect clears local credentials before Google revocation and retries failures durably", async () => {
  const f = await fixture();
  await f.connect();
  f.provider.revokeFails = true;
  const status = await f.service.disconnect(identity);
  equal(status.connected, false);
  equal(status.revocationPending, true);
  equal(f.repository.rows.get(userId)!.refresh_token_ciphertext, null);
  assert(!JSON.stringify(f.repository.jobs).includes(tokens.refreshToken!));
  await rejects(
    () => f.service.start(identity, "ios", undefined),
    "revocation_pending",
  );
  f.provider.revokeFails = false;
  equal(await f.service.revokePending(), 1);
  equal((await f.service.status(identity)).revocationPending, false);
  equal(f.provider.revoked[0], tokens.refreshToken);
});

Deno.test("refresh uses actual expiry and preserves an existing refresh token when Google omits rotation", async () => {
  const f = await fixture();
  await f.connect();
  f.repository.rows.get(userId)!.expires_at = new Date(0).toISOString();
  f.provider.refreshHook = () =>
    Promise.resolve({ accessToken: "new-google-access", expiresIn: 1200 });
  const response = await f.service.conflicts(identity, [slot]);
  equal(response.conflictingIds, ["slot"]);
  // Clients label this coverage and treat any other value as unchecked (F16).
  equal(response.coverage, "primary");
  equal(f.provider.refreshes, [tokens.refreshToken]);
  const row = f.repository.rows.get(userId)!;
  equal(
    await f.cipher.decrypt(
      row.refresh_token_ciphertext!,
      tokenPurpose(userId, "refresh"),
    ),
    tokens.refreshToken,
  );
  assert(Date.parse(row.expires_at!) > Date.now() + 1100000);
});

Deno.test("a refresh completing after disconnect cannot restore credentials", async () => {
  const f = await fixture();
  await f.connect();
  f.repository.rows.get(userId)!.expires_at = new Date(0).toISOString();
  let finish!: (value: TokenSet) => void;
  let signal!: () => void;
  const started = new Promise<void>((resolve) => {
    signal = resolve;
  });
  f.provider.refreshHook = () => {
    signal();
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const pending = f.service.conflicts(identity, [slot]);
  await started;
  await f.service.disconnect(identity);
  finish(tokens);
  await rejects(() => pending, "connection_changed");
  equal(f.repository.rows.get(userId)!.refresh_token_ciphertext, null);
});

Deno.test("revoked grants require reconnect instead of appearing conflict-free", async () => {
  const f = await fixture();
  await f.connect();
  f.repository.rows.get(userId)!.expires_at = new Date(0).toISOString();
  f.provider.refreshHook = () =>
    Promise.reject(new CalendarError("reconnect_required", 409, "Reconnect."));
  equal(
    (await f.handlers("conflicts")(request({ timeOptions: [slot] }))).status,
    409,
  );
  equal((await f.service.status(identity)).requiresReconnect, true);
});

Deno.test("Google failures are non-successful HTTP responses with no fabricated conflict list", async () => {
  const f = await fixture();
  await f.connect();
  f.provider.busyHook = () =>
    Promise.reject(
      new CalendarError(
        "provider_unavailable",
        503,
        "Could not check calendar.",
      ),
    );
  const response = await f.handlers("conflicts")(
    request({ timeOptions: [slot] }),
  );
  equal(response.status, 503);
  const body = await response.json();
  equal(body.success, false);
  assert(!("conflictingIds" in body));
  equal((await f.service.status(identity)).connected, true);
});

Deno.test("Google 401 is refreshed once and a repeated rejection invalidates the grant", async () => {
  const f = await fixture();
  await f.connect();
  f.provider.busyHook = () =>
    Promise.reject(
      new CalendarError("provider_unauthorized", 401, "Unauthorized."),
    );
  await rejects(
    () => f.service.conflicts(identity, [slot]),
    "provider_unauthorized",
  );
  equal(f.provider.refreshes.length, 1);
  equal((await f.service.status(identity)).requiresReconnect, true);
});

Deno.test("one FreeBusy request covers many slots and honors half-open interval boundaries", async () => {
  let calls = 0;
  const provider = new GoogleCalendarProvider(
    "client",
    "server-secret",
    "https://project.example.test/callback",
    (_input, init) => {
      calls++;
      const input = JSON.parse(init!.body as string);
      equal(input.items, [{ id: "primary" }]);
      return Promise.resolve(Response.json({
        calendars: {
          primary: { busy: [{ start: slot.start_time, end: slot.end_time }] },
        },
      }));
    },
  );
  const f = await fixture();
  await f.connect();
  const service = new CalendarService(f.repository, provider, f.cipher, {
    webOrigins: [],
    mobileReturnURL: "meetingscheduler://calendar/callback",
  });
  const options = [slot, {
    id: "before",
    start_time: "2026-11-02T14:00:00Z",
    end_time: slot.start_time,
  }, {
    id: "after",
    start_time: slot.end_time,
    end_time: "2026-11-02T17:00:00Z",
  }];
  equal((await service.conflicts(identity, options)).conflictingIds, ["slot"]);
  equal(calls, 1);
});

Deno.test("FreeBusy per-calendar errors and malformed coverage are failures, even with HTTP 200", async () => {
  for (
    const payload of [
      {
        calendars: {
          primary: { errors: [{ reason: "internalError" }], busy: [] },
        },
      },
      { calendars: {} },
      {
        calendars: {
          primary: { busy: [{ start: "invalid", end: "invalid" }] },
        },
      },
    ]
  ) {
    const provider = new GoogleCalendarProvider(
      "client",
      "secret",
      "https://project.example.test/callback",
      () => Promise.resolve(Response.json(payload)),
    );
    await rejects(
      () => provider.freeBusy("access", slot.start_time, slot.end_time),
      "provider_response_invalid",
    );
  }
});

Deno.test("option validation bounds workload and rejects duplicate IDs, naive timestamps and invalid ranges", async () => {
  for (
    const value of [
      [],
      Array(201).fill(slot),
      [slot, slot],
      [{ ...slot, start_time: "2026-11-02T15:00:00" }],
      [{ ...slot, end_time: slot.start_time }],
      [slot, {
        ...slot,
        id: "far",
        start_time: "2027-11-02T15:00:00Z",
        end_time: "2027-11-02T16:00:00Z",
      }],
    ]
  ) {
    await rejects(() => parseOptions(value), "invalid_options");
  }
  equal(parseOptions([slot]), [slot]);
});

Deno.test("HTTP enforces methods, origin allowlists, input size and bearer authentication", async () => {
  const f = await fixture();
  equal(
    (await f.handlers("connection")(
      new Request("https://project.example.test/function"),
    )).status,
    405,
  );
  equal(
    (await f.handlers("connection")(
      request({ action: "status" }, "verified-test-token", {
        Origin: "https://evil.example",
      }),
    )).status,
    403,
  );
  equal(
    (await f.handlers("connection")(
      request({ action: "status", padding: "x".repeat(65536) }),
    )).status,
    413,
  );
  const response = await f.handlers("connection")(
    request({ action: "status" }, "verified-test-token", {
      Origin: "https://web.example.test",
    }),
  );
  equal(
    response.headers.get("Access-Control-Allow-Origin"),
    "https://web.example.test",
  );
  equal(response.headers.get("Cache-Control"), "no-store");
  equal(response.headers.get("Referrer-Policy"), "no-referrer");
});

Deno.test("maintenance requires a separate server credential and key rotation never returns plaintext", async () => {
  const old = await TokenCipher.create("old", { old: key });
  const f = await fixture(old);
  await f.connect();
  const next = await TokenCipher.create("next", { old: key, next: nextKey });
  const service = new CalendarService(f.repository, f.provider, next, {
    webOrigins: [],
    mobileReturnURL: "meetingscheduler://calendar/callback",
  });
  equal(await service.rotateKeys(), 1);
  equal(
    JSON.parse(f.repository.rows.get(userId)!.refresh_token_ciphertext!).key_id,
    "next",
  );
  const handler = calendarHandler("maintenance", {
    service,
    webOrigins: [],
    authenticate: () =>
      Promise.reject(
        new Error("User authentication must not authorize maintenance"),
      ),
    authorizeMaintenance: (req) =>
      req.headers.get("Authorization") === "Bearer maintenance-only"
        ? Promise.resolve()
        : Promise.reject(
          new CalendarError(
            "authentication_required",
            401,
            "Authentication required.",
          ),
        ),
  });
  equal((await handler(request({}))).status, 401);
  const response = await handler(request({}, "maintenance-only"));
  equal(response.status, 200);
  assert(!/google-refresh-secret|ciphertext/.test(await response.text()));
});

import { createClient } from "npm:@supabase/supabase-js@2.89.0";
import { base64url } from "./crypto.ts";
import { authenticateCalendar } from "./identity.ts";
import { CalendarError, type Operation, type Repository } from "./types.ts";

Deno.test("actual Supabase SDK verifies ES256 signatures before privileged session lookup", async () => {
  const issuer = "https://project.example.test/auth/v1";
  const userId = "00000000-0000-4000-8000-000000000001";
  const sessionId = "00000000-0000-4000-8000-000000000002";
  const keys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const publicKey = {
    ...await crypto.subtle.exportKey("jwk", keys.publicKey),
    kid: "test-key",
    alg: "ES256",
    use: "sig",
  };
  let privilegedLookups = 0;
  const repository: Repository = {
    call<T>(operation: Operation) {
      if (operation !== "session") {
        throw new Error("Unexpected privileged operation");
      }
      privilegedLookups++;
      return Promise.resolve(true as T);
    },
  };
  const auth = createClient(
    "https://project.example.test",
    "synthetic-anon-key",
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
      global: {
        fetch: (input) => {
          if (!String(input).endsWith("/auth/v1/.well-known/jwks.json")) {
            throw new Error("Unexpected network request");
          }
          return Promise.resolve(Response.json({ keys: [publicKey] }));
        },
      },
    },
  );
  const encode = (value: unknown) =>
    base64url(new TextEncoder().encode(JSON.stringify(value)));
  const header = encode({ alg: "ES256", typ: "JWT", kid: "test-key" });
  const payload = encode({
    sub: userId,
    session_id: sessionId,
    iss: issuer,
    aud: "authenticated",
    role: "authenticated",
    exp: Math.floor(Date.now() / 1000) + 3600,
    iat: Math.floor(Date.now() / 1000),
  });
  const signature = base64url(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        keys.privateKey,
        new TextEncoder().encode(header + "." + payload),
      ),
    ),
  );
  const token = header + "." + payload + "." + signature;
  const verify = async (value: string) => {
    const { data, error } = await auth.auth.getClaims(value);
    return error ? null : data?.claims ?? null;
  };
  const request = (value: string) =>
    new Request("https://project.example.test/calendar-connection", {
      headers: { Authorization: "Bearer " + value },
    });
  const identity = await authenticateCalendar(
    request(token),
    verify,
    repository,
    issuer,
  );
  if (identity.userId !== userId || privilegedLookups !== 1) {
    throw new Error("Valid signature was not verified");
  }
  const forgedPayload = encode({
    sub: "00000000-0000-4000-8000-000000000099",
    session_id: sessionId,
    iss: issuer,
    aud: "authenticated",
    role: "authenticated",
    exp: Math.floor(Date.now() / 1000) + 3600,
  });
  try {
    await authenticateCalendar(
      request(header + "." + forgedPayload + "." + signature),
      verify,
      repository,
      issuer,
    );
    throw new Error("Forged signature was accepted");
  } catch (error) {
    if (
      !(error instanceof CalendarError) ||
      error.code !== "authentication_required"
    ) throw error;
  }
  if (privilegedLookups !== 1) {
    throw new Error("Forged identity reached privileged storage");
  }
});

import { CalendarError, type Identity, type Repository } from "./types.ts";

const UUID =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
export type VerifiedClaims = (
  token: string,
) => Promise<Record<string, unknown> | null>;

/** verify must perform cryptographic verification, never just decode a JWT. */
export async function authenticateCalendar(
  request: Request,
  verify: VerifiedClaims,
  repository: Repository,
  issuer: string,
  now = Date.now(),
): Promise<Identity> {
  const failure = () =>
    new CalendarError("authentication_required", 401, "Sign in to continue.");
  const authorization = request.headers.get("Authorization");
  if (
    !authorization?.startsWith("Bearer ") || authorization.length <= 7 ||
    authorization.length > 20000
  ) throw failure();
  let claims: Record<string, unknown> | null;
  try {
    claims = await verify(authorization.substring(7));
  } catch {
    throw failure();
  }
  const audience = claims?.aud;
  if (
    !claims || typeof claims.sub !== "string" || !UUID.test(claims.sub) ||
    typeof claims.session_id !== "string" || !UUID.test(claims.session_id) ||
    claims.role !== "authenticated" || claims.iss !== issuer ||
    claims.is_anonymous === true ||
    (audience !== "authenticated" &&
      !(Array.isArray(audience) && audience.includes("authenticated"))) ||
    typeof claims.exp !== "number" || claims.exp * 1000 <= now
  ) throw failure();
  const userId = claims.sub.toLowerCase(),
    sessionId = claims.session_id.toLowerCase();
  if (
    !await repository.call<boolean>("session", userId, {
      session_id: sessionId,
    })
  ) throw failure();
  return { userId, sessionId };
}

import {
  type BusyInterval,
  CalendarError,
  type Provider,
  type TokenSet,
} from "./types.ts";

export const CALENDAR_SCOPE =
  "https://www.googleapis.com/auth/calendar.events.freebusy";
const TIMEOUT_MS = 10000;

export class GoogleCalendarProvider implements Provider {
  constructor(
    private clientId: string,
    private clientSecret: string,
    private redirectURI: string,
    private fetcher: typeof fetch = fetch,
  ) {}

  authorizationURL(state: string, challenge: string): string {
    const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    url.search = new URLSearchParams({
      client_id: this.clientId,
      redirect_uri: this.redirectURI,
      response_type: "code",
      scope: `openid email ${CALENDAR_SCOPE}`,
      state,
      code_challenge: challenge,
      code_challenge_method: "S256",
      access_type: "offline",
      prompt: "consent select_account",
      include_granted_scopes: "false",
    }).toString();
    return url.toString();
  }

  private async tokens(parameters: Record<string, string>): Promise<TokenSet> {
    let response: Response;
    try {
      response = await this.fetcher("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          ...parameters,
          client_id: this.clientId,
          client_secret: this.clientSecret,
        }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch {
      throw new CalendarError(
        "provider_unavailable",
        503,
        "Google Calendar is temporarily unavailable.",
      );
    }
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (body.error === "invalid_grant") {
        throw new CalendarError(
          "reconnect_required",
          409,
          "Reconnect Google Calendar.",
        );
      }
      throw new CalendarError(
        "provider_unavailable",
        503,
        "Google Calendar is temporarily unavailable.",
      );
    }
    if (
      typeof body.access_token !== "string" ||
      body.access_token.length > 16000 ||
      !body.access_token || body.token_type?.toLowerCase() !== "bearer" ||
      !Number.isFinite(body.expires_in) || body.expires_in <= 0 ||
      body.expires_in > 86400 ||
      (body.refresh_token !== undefined &&
        (typeof body.refresh_token !== "string" || !body.refresh_token ||
          body.refresh_token.length > 16000))
    ) {
      throw new CalendarError(
        "provider_response_invalid",
        502,
        "Google returned an invalid authorization response.",
      );
    }
    return {
      accessToken: body.access_token,
      refreshToken: body.refresh_token,
      expiresIn: body.expires_in,
      scopes: typeof body.scope === "string"
        ? body.scope.split(" ")
        : undefined,
    };
  }

  exchange(code: string, verifier: string): Promise<TokenSet> {
    return this.tokens({
      code,
      code_verifier: verifier,
      redirect_uri: this.redirectURI,
      grant_type: "authorization_code",
    });
  }

  refresh(refreshToken: string): Promise<TokenSet> {
    return this.tokens({
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });
  }

  async userInfo(
    accessToken: string,
  ): Promise<{ subject: string; email: string }> {
    const response = await this.fetcher(
      "https://openidconnect.googleapis.com/v1/userinfo",
      {
        headers: { Authorization: `Bearer ${accessToken}` },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      },
    );
    const info = await response.json().catch(() => ({}));
    if (
      !response.ok || typeof info.sub !== "string" || info.sub.length > 255 ||
      !info.sub ||
      typeof info.email !== "string" || info.email.length > 320 ||
      info.email_verified !== true
    ) {
      throw new CalendarError(
        "provider_identity_invalid",
        502,
        "Google account could not be verified.",
      );
    }
    return { subject: info.sub, email: info.email };
  }

  async freeBusy(
    accessToken: string,
    start: string,
    end: string,
  ): Promise<BusyInterval[]> {
    let response: Response;
    try {
      response = await this.fetcher(
        "https://www.googleapis.com/calendar/v3/freeBusy",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            timeMin: start,
            timeMax: end,
            items: [{ id: "primary" }],
          }),
          signal: AbortSignal.timeout(TIMEOUT_MS),
        },
      );
    } catch {
      throw new CalendarError(
        "provider_unavailable",
        503,
        "Calendar conflicts could not be checked.",
      );
    }
    if (response.status === 401) {
      throw new CalendarError(
        "provider_unauthorized",
        401,
        "Reconnect Google Calendar.",
      );
    }
    if (!response.ok) {
      throw new CalendarError(
        "provider_unavailable",
        503,
        "Calendar conflicts could not be checked.",
      );
    }
    const body = await response.json().catch(() => ({}));
    const calendar = body.calendars?.primary;
    if (
      !calendar || calendar.errors?.length || !Array.isArray(calendar.busy) ||
      !calendar.busy.every((interval: BusyInterval) =>
        typeof interval.start === "string" &&
        typeof interval.end === "string" &&
        Number.isFinite(Date.parse(interval.start)) &&
        Date.parse(interval.end) > Date.parse(interval.start)
      )
    ) {
      throw new CalendarError(
        "provider_response_invalid",
        502,
        "Calendar coverage could not be verified.",
      );
    }
    return calendar.busy.map(({ start, end }: BusyInterval) => ({
      start,
      end,
    }));
  }

  async revoke(refreshToken: string): Promise<void> {
    const response = await this.fetcher(
      "https://oauth2.googleapis.com/revoke",
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token: refreshToken }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      },
    );
    // Google's documented invalid_token response also means the grant is gone.
    if (response.status === 400) {
      const body = await response.json().catch(() => ({}));
      if (body.error === "invalid_token") return;
    }
    if (!response.ok) {
      throw new CalendarError(
        "revocation_pending",
        503,
        "Google revocation will be retried.",
      );
    }
  }
}

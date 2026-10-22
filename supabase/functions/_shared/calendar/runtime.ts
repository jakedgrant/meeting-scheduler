import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.89.0";
import { TokenCipher } from "./crypto.ts";
import { GoogleCalendarProvider } from "./google.ts";
import { CalendarService } from "./service.ts";
import {
  CalendarError,
  type Identity,
  type Operation,
  type Repository,
} from "./types.ts";
import { calendarHandler, type HandlerDependencies } from "./http.ts";
import { authenticateCalendar } from "./identity.ts";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing calendar server configuration");
  return value;
}

function trustedHTTPURL(value: string): URL {
  const url = new URL(value);
  if (
    url.username || url.password || url.hash ||
    (url.protocol !== "https:" &&
      !(url.protocol === "http:" &&
        ["localhost", "127.0.0.1"].includes(url.hostname)))
  ) {
    throw new Error("Invalid calendar server URL");
  }
  return url;
}

type CalendarDatabase = {
  public: {
    Tables: Record<string, never>;
    Views: Record<string, never>;
    Functions: {
      calendar_admin: {
        Args: {
          p_action: Operation;
          p_user_id: string | null;
          p_data: Record<string, unknown>;
        };
        Returns: unknown;
      };
    };
  };
};

class SupabaseCalendarRepository implements Repository {
  constructor(private admin: SupabaseClient<CalendarDatabase>) {}
  async call<T>(
    action: Operation,
    userId?: string,
    data: Record<string, unknown> = {},
  ): Promise<T> {
    const result = await this.admin.rpc("calendar_admin", {
      p_action: action,
      p_user_id: userId ?? null,
      p_data: data,
    });
    if (result.error) {
      if (result.error.code === "55000") {
        throw new CalendarError(
          "calendar_operation_pending",
          409,
          "Another calendar operation is finishing. Try again shortly.",
        );
      }
      throw new CalendarError(
        "calendar_storage_unavailable",
        503,
        "Calendar storage is temporarily unavailable.",
      );
    }
    return result.data as T;
  }
}

export async function runtime(): Promise<HandlerDependencies> {
  const supabaseURL = required("SUPABASE_URL").replace(/\/$/, "");
  const clientOptions = {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  };
  const auth = createClient(
    supabaseURL,
    required("SUPABASE_ANON_KEY"),
    clientOptions,
  );
  const repository = new SupabaseCalendarRepository(
    createClient<CalendarDatabase>(
      supabaseURL,
      required("SUPABASE_SERVICE_ROLE_KEY"),
      clientOptions,
    ),
  );
  const issuer = Deno.env.get("CALENDAR_JWT_ISSUER") ??
    supabaseURL + "/auth/v1";
  const webOrigins = required("CALENDAR_ALLOWED_WEB_ORIGINS").split(",").map(
    (value) => {
      const url = trustedHTTPURL(value.trim());
      if (url.pathname !== "/" || url.search) {
        throw new Error("Calendar origins must be origins only");
      }
      return url.origin;
    },
  );
  const callback = trustedHTTPURL(
    Deno.env.get("CALENDAR_OAUTH_REDIRECT_URI") ??
      supabaseURL + "/functions/v1/calendar-oauth-callback",
  );
  const cipher = await TokenCipher.create(
    required("CALENDAR_TOKEN_KEY_ID"),
    JSON.parse(required("CALENDAR_TOKEN_KEYS")),
  );
  const provider = new GoogleCalendarProvider(
    required("CALENDAR_GOOGLE_CLIENT_ID"),
    required("CALENDAR_GOOGLE_CLIENT_SECRET"),
    callback.toString(),
  );
  const service = new CalendarService(repository, provider, cipher, {
    webOrigins,
    mobileReturnURL: "meetingscheduler://calendar/callback",
  });
  return {
    service,
    webOrigins,
    authenticate(request: Request): Promise<Identity> {
      // The SDK validates the signature using project signing keys (or Auth for
      // legacy keys). No decoded, caller-supplied header is trusted as identity.
      return authenticateCalendar(
        request,
        async (token) => {
          const { data, error } = await auth.auth.getClaims(token);
          return error ? null : data?.claims ?? null;
        },
        repository,
        issuer,
      );
    },
    async authorizeMaintenance(request: Request): Promise<void> {
      const secret = required("CALENDAR_MAINTENANCE_SECRET");
      const supplied = request.headers.get("Authorization") ?? "";
      if (secret.length < 43) {
        throw new Error(
          "Invalid maintenance configuration",
        );
      }
      // Compare fixed-size digests; do not print either header or secret.
      const encode = new TextEncoder();
      const expected = new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          encode.encode("Bearer " + secret),
        ),
      );
      const actual = new Uint8Array(
        await crypto.subtle.digest("SHA-256", encode.encode(supplied)),
      );
      let difference = 0;
      for (let index = 0; index < expected.length; index++) {
        difference |= expected[index] ^ actual[index];
      }
      if (difference !== 0) {
        throw new CalendarError(
          "authentication_required",
          401,
          "Authentication required.",
        );
      }
    },
  };
}

export function serveCalendar(
  kind: "connection" | "conflicts" | "callback" | "maintenance",
) {
  // Cache only immutable configuration/clients, never a user's session or token.
  let dependencies: Promise<HandlerDependencies> | undefined;
  Deno.serve(async (request) => {
    try {
      dependencies ??= runtime().catch((error) => {
        dependencies = undefined;
        throw error;
      });
      return await calendarHandler(kind, await dependencies)(request);
    } catch {
      console.error("calendar_configuration_unavailable");
      return Response.json({
        success: false,
        error: "calendar_unavailable",
        message: "Calendar service is temporarily unavailable.",
      }, {
        status: 503,
        headers: {
          "Cache-Control": "no-store",
          "Referrer-Policy": "no-referrer",
        },
      });
    }
  });
}

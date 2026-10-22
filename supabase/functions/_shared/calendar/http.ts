import { CalendarError, type Identity } from "./types.ts";
import { CalendarService, parseOptions } from "./service.ts";

export interface HandlerDependencies {
  service: CalendarService;
  authenticate(request: Request): Promise<Identity>;
  authorizeMaintenance(request: Request): Promise<void>;
  webOrigins: string[];
}

function headers(request: Request, origins: string[]): Headers {
  const result = new Headers({
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Vary": "Origin",
  });
  const origin = request.headers.get("Origin");
  if (origin && origins.includes(origin)) {
    result.set("Access-Control-Allow-Origin", origin);
    result.set(
      "Access-Control-Allow-Headers",
      "authorization, apikey, content-type, x-client-info",
    );
    result.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  }
  return result;
}

async function body(request: Request): Promise<Record<string, unknown>> {
  if (
    !request.headers.get("Content-Type")?.toLowerCase().startsWith(
      "application/json",
    )
  ) {
    throw new CalendarError(
      "invalid_request",
      415,
      "A JSON request is required.",
    );
  }
  // Stream with a byte limit; do not buffer an unbounded caller-controlled body.
  const reader = request.body?.getReader();
  if (!reader) {
    throw new CalendarError(
      "invalid_request",
      400,
      "A JSON request is required.",
    );
  }
  const parts: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 65536) {
      await reader.cancel();
      throw new CalendarError(
        "request_too_large",
        413,
        "Request is too large.",
      );
    }
    parts.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.byteLength;
  }
  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new CalendarError("invalid_request", 400, "Invalid JSON request.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new CalendarError("invalid_request", 400, "Invalid JSON request.");
  }
  return parsed;
}

function onlyKeys(value: Record<string, unknown>, allowed: string[]) {
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    throw new CalendarError(
      "invalid_request",
      400,
      "Unexpected request fields.",
    );
  }
}

export function calendarHandler(
  kind: "connection" | "conflicts" | "callback" | "maintenance",
  deps: HandlerDependencies,
) {
  return async (request: Request): Promise<Response> => {
    const responseHeaders = headers(request, deps.webOrigins);
    const requestId = crypto.randomUUID();
    responseHeaders.set("X-Request-Id", requestId);
    try {
      if (kind !== "callback" && request.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: responseHeaders });
      }
      if (request.method !== (kind === "callback" ? "GET" : "POST")) {
        throw new CalendarError(
          "method_not_allowed",
          405,
          "Unsupported request method.",
        );
      }
      const origin = request.headers.get("Origin");
      if (kind !== "callback" && origin && !deps.webOrigins.includes(origin)) {
        throw new CalendarError(
          "origin_not_allowed",
          403,
          "Unsupported request origin.",
        );
      }
      if (kind === "callback") {
        const location = await deps.service.callback(
          new URL(request.url).searchParams,
        );
        responseHeaders.set("Location", location);
        return new Response(null, { status: 303, headers: responseHeaders });
      }
      if (kind === "maintenance") {
        await deps.authorizeMaintenance(request);
        return Response.json({
          revoked: await deps.service.revokePending(),
          rotated: await deps.service.rotateKeys(),
        }, { headers: responseHeaders });
      }
      const identity = await deps.authenticate(request);
      const input = await body(request);
      let result;
      if (kind === "conflicts") {
        onlyKeys(input, ["timeOptions"]);
        result = await deps.service.conflicts(
          identity,
          parseOptions(input.timeOptions),
        );
      } else {
        if (input.action === "status") {
          onlyKeys(input, ["action"]);
          result = await deps.service.status(identity);
        } else if (input.action === "disconnect") {
          onlyKeys(input, ["action"]);
          result = await deps.service.disconnect(identity);
        } else if (input.action === "start") {
          onlyKeys(input, ["action", "target", "origin"]);
          result = await deps.service.start(
            identity,
            input.target,
            input.origin,
          );
        } else {
          throw new CalendarError(
            "invalid_action",
            400,
            "Unsupported calendar action.",
          );
        }
      }
      return Response.json(result, { headers: responseHeaders });
    } catch (error) {
      const failure = error instanceof CalendarError
        ? error
        : new CalendarError(
          "calendar_unavailable",
          503,
          "Calendar service is temporarily unavailable.",
        );
      console.warn("calendar_request_failed", {
        requestId,
        code: failure.code,
      });
      return Response.json({
        success: false,
        error: failure.code,
        message: failure.message,
        requestId,
      }, { status: failure.status, headers: responseHeaders });
    }
  };
}

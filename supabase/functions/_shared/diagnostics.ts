// Backend log lines carry only these fields, whatever object a caller passes. Headers,
// payloads, user identifiers and raw provider or database errors have no field here,
// and callers keep the string fields to stable codes and opaque IDs.
export interface DiagnosticFields {
  requestId?: string;
  jobId?: string;
  kind?: string;
  status?: number;
  durationMs?: number;
}

export function logEvent(
  level: "info" | "warn" | "error",
  component: string,
  code: string,
  { requestId, jobId, kind, status, durationMs }: DiagnosticFields = {},
) {
  console[level](
    JSON.stringify({
      component,
      code,
      requestId,
      jobId,
      kind,
      status,
      durationMs,
    }),
  );
}

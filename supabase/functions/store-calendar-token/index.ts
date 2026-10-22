// Deploy this tombstone with the new endpoints so previously deployed versions
// cannot keep reading provider credentials from Supabase Auth identities.
Deno.serve(() =>
  Response.json({
    error: "calendar_authorization_moved",
    message: "Connect Google Calendar from the updated app Settings.",
  }, {
    status: 410,
    headers: { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" },
  })
);

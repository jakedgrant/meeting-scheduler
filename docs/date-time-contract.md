# Date and time contract (F21)

Polls mix three kinds of value. Each has one representation, and every client converts between them with the same rules. Shared fixtures: [`packages/shared-config/date-time-fixtures.json`](../packages/shared-config/date-time-fixtures.json).

| Kind | Representation | Examples |
| --- | --- | --- |
| Calendar date | `YYYY-MM-DD`, no zone | A picked option date, a response due date, an all-day option's date |
| Zoned wall time | Calendar date + `HH:MM` + IANA zone | "9:00 on 2026-11-02 in America/Chicago" |
| Instant | `timestamptz`; clients send UTC `YYYY-MM-DDTHH:MM:SSZ` | `start_time`, `end_time`, `closes_at`, `selected_*` |

`polls.timezone` is the IANA zone the creator's client used to resolve picker values, normally the device or browser zone at creation. It is the zone of the poll's scheduling intent. Instants are stored and compared as instants; only date-shaped values depend on the zone.

## Rules

1. **Date arithmetic is date-only.** A range from D1 through D2 contains each calendar date once, inclusive. It never passes through a host-local `Date`, so clock changes cannot skip or repeat a date. A reversed range is rejected.
2. **Wall times resolve in the poll zone.** A wall time skipped by a clock change (for example 02:30 on 2026-03-08 in Chicago) is rejected with a message asking for another time. A repeated wall time (01:30 on 2026-11-01 in Chicago) uses its first occurrence, the earlier offset. The end wall time must be after the start wall time on the same date.
3. **An all-day option is one calendar date.** It is stored as `[start of D, start of D+1)` in the poll zone, with `is_all_day = true`. The start of a date is local midnight, or the first time after the gap when midnight itself is skipped (America/Santiago on 2026-09-06 starts at 01:00). Days can be 23 or 25 hours long, so the end is never "start + 24 hours" or "23:59".
4. **A due date covers the whole day.** Due date D sets `closes_at` to the start of D+1 in the poll zone. Responses are accepted through the end of D. A client restoring a draft maps a deadline back to the date containing `closes_at - 1 second`.
5. **All-day dates are read in the poll zone.** Every viewer sees the poll's calendar date, regardless of their own zone. Clients take the date from `start_time` in `polls.timezone`, so legacy rows ending at 23:59 show the same date. Timed options are instants and are shown in the viewer's zone.
6. **Exports keep all-day dates floating.** ICS uses `DTSTART;VALUE=DATE:D` and `DTEND;VALUE=DATE:D+1`; Google Calendar uses `dates=D/D+1`; iOS EventKit and the Android insert intent set their all-day flag. Timed events export UTC instants.

## Enforcement

[`20261025021513_all_day_time_options.sql`](../supabase/migrations/20261025021513_all_day_time_options.sql) checks rule 3 for every new or changed all-day interval, through `create_poll` and direct option writes alike. A misaligned interval fails with SQLSTATE `22023` and the whole creation rolls back. The check asks whether each bound is the first instant of its date in the poll zone, so it does not depend on how PostgreSQL resolves a skipped or repeated wall time. The timezone of a poll with all-day options cannot change, because that would move their dates.

Existing rows are not rewritten or revalidated. A legacy all-day option keeps its 23:59 end until its interval is edited; clients display and export it by its start date. Gap/ambiguity handling, rule 2, and the due-date rule are client encodings: the backend receives instants and cannot recover the wall time the user picked.

| Client | Implementation | Tests |
| --- | --- | --- |
| Web | [`date-time.ts`](../apps/web/src/lib/date-time.ts), used by creation, the date pickers, option display and [calendar exports](../apps/web/src/lib/calendar-utils.ts) | `npm run test:web:dates` (fixtures in five host zones) |
| iOS | [`CalendarDay.swift`](../apps/mobile/Sources/Shared/Models/CalendarDay.swift), used by `CreatePollView`, detail rows and EventKit export | `DateTimeContractTests` in the package test target |
| Android | [`PollDates.kt`](../apps/android/app/src/main/kotlin/com/meetingscheduler/android/models/PollDates.kt), used by `CreatePollView`, detail rows and the calendar insert intent | `PollDatesTest` (JVM) |
| Database | Migration above | `npm run test:dates:db` (also part of `npm run test:database`) |

## Fixtures

[`scripts/generate-date-time-fixtures.py`](../scripts/generate-date-time-fixtures.py) computes the expected values with Python's `zoneinfo`, independently of the four implementations. Regenerate with `python3 -I scripts/generate-date-time-fixtures.py` after adding a case, and review the diff. A tz database release that changes a fixture zone's rules for 2026–2028 changes expected values for every client at once, which is the intent.

The fixtures cover Chicago spring-forward and fall-back weeks, year and leap-day ranges, half-hour (Kolkata) and southern-hemisphere (Auckland) offsets, a missing local midnight (Santiago), skipped and repeated wall times, legacy 23:59 ends and export formats.

## Out of scope

F16 owns calendar coverage: whether busy all-day events, secondary calendars and provider uncertainty count as conflicts. It should consume these all-day bounds. The polls list date range (F18) still shows start instants in the viewer's zone. Changing the creation zone is not offered in the UI; a poll uses the creating device's zone.

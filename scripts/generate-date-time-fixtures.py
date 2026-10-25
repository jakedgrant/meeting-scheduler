#!/usr/bin/env python3
"""Generate packages/shared-config/date-time-fixtures.json (F21).

Expected values come from Python's zoneinfo, independently of the web, iOS,
Android and PostgreSQL implementations that are tested against them. The rules
are documented in docs/date-time-contract.md. Run with `python3 -I` and commit
the output; clients read the committed file and never run this script.
"""
import json
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

UTC = timezone.utc


def instant(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve(day: date, wall: time, zone: str) -> datetime:
    """Wall time in zone. Gaps are rejected; repeated times use the earlier offset."""
    local = datetime.combine(day, wall)
    aware = local.replace(tzinfo=ZoneInfo(zone), fold=0)
    if aware.astimezone(UTC).astimezone(ZoneInfo(zone)).replace(tzinfo=None) != local:
        raise ValueError("nonexistent_local_time")
    return aware


def start_of_day(day: date, zone: str) -> datetime:
    """First instant of a calendar date; after a midnight gap that is the first valid time."""
    try:
        return resolve(day, time(0, 0), zone)
    except ValueError:
        # fold=0 maps a skipped midnight through the pre-transition offset, which
        # lands on the first existing wall time after the gap.
        return datetime.combine(day, time(0, 0)).replace(tzinfo=ZoneInfo(zone), fold=0)


def dates(start: str, end: str) -> list[str]:
    first, last = date.fromisoformat(start), date.fromisoformat(end)
    return [(first + timedelta(days=n)).isoformat() for n in range((last - first).days + 1)]


def timed(name, zone, day, start, end):
    case = {"name": name, "zone": zone, "date": day, "start": start, "end": end}
    try:
        d = date.fromisoformat(day)
        if time.fromisoformat(end) <= time.fromisoformat(start):
            raise ValueError("end_not_after_start")
        a, b = resolve(d, time.fromisoformat(start), zone), resolve(d, time.fromisoformat(end), zone)
        case.update(start_time=instant(a), end_time=instant(b))
    except ValueError as error:
        case["error"] = str(error)
    return case


def all_day(name, zone, day):
    d = date.fromisoformat(day)
    return {"name": name, "zone": zone, "date": day,
            "start_time": instant(start_of_day(d, zone)),
            "end_time": instant(start_of_day(d + timedelta(days=1), zone))}


def deadline(name, zone, day):
    d = date.fromisoformat(day)
    return {"name": name, "zone": zone, "date": day, "closes_at": instant(start_of_day(d + timedelta(days=1), zone))}


def option_date(name, zone, start_time, end_time):
    start = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
    return {"name": name, "zone": zone, "start_time": start_time, "end_time": end_time, "is_all_day": True,
            "date": start.astimezone(ZoneInfo(zone)).date().isoformat()}


def export(name, zone, start_time, end_time, is_all_day):
    start = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
    end = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
    if is_all_day:
        first = start.astimezone(ZoneInfo(zone)).date()
        # One all-day option covers one calendar date; legacy 23:59 ends map to the same date.
        a, b = first.strftime("%Y%m%d"), (first + timedelta(days=1)).strftime("%Y%m%d")
        ics = (f"DTSTART;VALUE=DATE:{a}", f"DTEND;VALUE=DATE:{b}")
    else:
        a, b = start.strftime("%Y%m%dT%H%M%SZ"), end.strftime("%Y%m%dT%H%M%SZ")
        ics = (f"DTSTART:{a}", f"DTEND:{b}")
    return {"name": name, "zone": zone, "start_time": start_time, "end_time": end_time, "is_all_day": is_all_day,
            "ics_start": ics[0], "ics_end": ics[1], "google_dates": f"{a}/{b}"}


CHI = "America/Chicago"
fixtures = {
    "version": 1,
    "contract": "docs/date-time-contract.md",
    "generator": "scripts/generate-date-time-fixtures.py",
    "date_ranges": [
        {"name": "Chicago fall-back week", "start": "2026-10-31", "end": "2026-11-03", "dates": dates("2026-10-31", "2026-11-03")},
        {"name": "Chicago spring-forward week", "start": "2026-03-07", "end": "2026-03-10", "dates": dates("2026-03-07", "2026-03-10")},
        {"name": "Single date", "start": "2026-11-01", "end": "2026-11-01", "dates": ["2026-11-01"]},
        {"name": "Year boundary", "start": "2026-12-30", "end": "2027-01-02", "dates": dates("2026-12-30", "2027-01-02")},
        {"name": "Leap day", "start": "2028-02-27", "end": "2028-03-01", "dates": dates("2028-02-27", "2028-03-01")},
        {"name": "Reversed range", "start": "2026-11-03", "end": "2026-11-01", "dates": []},
    ],
    "timed_options": [
        timed("Chicago standard time", CHI, "2026-11-02", "09:00", "10:00"),
        timed("Chicago daylight time", CHI, "2026-10-30", "09:00", "10:00"),
        timed("Chicago spring-forward day", CHI, "2026-03-08", "09:00", "10:00"),
        timed("Chicago fall-back day", CHI, "2026-11-01", "09:00", "10:00"),
        timed("Repeated hour uses earlier offset", CHI, "2026-11-01", "01:30", "01:45"),
        timed("Range spanning the repeated hour", CHI, "2026-11-01", "01:30", "02:00"),
        timed("Start in spring-forward gap", CHI, "2026-03-08", "02:30", "03:30"),
        timed("End in spring-forward gap", CHI, "2026-03-08", "01:00", "02:15"),
        timed("End before start", CHI, "2026-11-02", "10:00", "09:00"),
        timed("Equal start and end", CHI, "2026-11-02", "10:00", "10:00"),
        timed("Half-hour offset", "Asia/Kolkata", "2026-11-01", "09:00", "10:00"),
        timed("Southern hemisphere daylight time", "Pacific/Auckland", "2026-11-01", "09:00", "10:00"),
        timed("Previous UTC date", "Pacific/Auckland", "2026-11-01", "08:00", "23:45"),
        timed("UTC", "UTC", "2026-11-01", "23:00", "23:45"),
    ],
    "all_day_options": [
        all_day("Chicago 25-hour day", CHI, "2026-11-01"),
        all_day("Chicago 23-hour day", CHI, "2026-03-08"),
        all_day("Chicago ordinary day", CHI, "2026-11-03"),
        all_day("Half-hour offset", "Asia/Kolkata", "2026-11-01"),
        all_day("Ahead of UTC", "Pacific/Auckland", "2026-11-01"),
        all_day("Missing local midnight", "America/Santiago", "2026-09-06"),
        all_day("Day before missing midnight", "America/Santiago", "2026-09-05"),
        all_day("UTC", "UTC", "2026-11-01"),
    ],
    "deadlines": [
        deadline("Chicago end of due date", CHI, "2026-11-03"),
        deadline("Chicago due on fall-back eve", CHI, "2026-10-31"),
        deadline("Ahead of UTC", "Pacific/Auckland", "2026-11-01"),
        deadline("Next day has missing midnight", "America/Santiago", "2026-09-05"),
    ],
    "option_dates": [
        option_date("Exclusive all-day end", CHI, "2026-11-01T05:00:00Z", "2026-11-02T06:00:00Z"),
        option_date("Legacy 23:59 all-day end", CHI, "2026-11-01T05:00:00Z", "2026-11-02T05:59:00Z"),
        option_date("Ahead of UTC", "Pacific/Auckland", "2026-10-31T11:00:00Z", "2026-11-01T11:00:00Z"),
        option_date("Missing local midnight", "America/Santiago", "2026-09-06T04:00:00Z", "2026-09-07T03:00:00Z"),
    ],
    "exports": [
        export("All-day exclusive end", CHI, "2026-11-01T05:00:00Z", "2026-11-02T06:00:00Z", True),
        export("All-day legacy 23:59 end", CHI, "2026-11-01T05:00:00Z", "2026-11-02T05:59:00Z", True),
        export("All-day ahead of UTC", "Pacific/Auckland", "2026-10-31T11:00:00Z", "2026-11-01T11:00:00Z", True),
        export("Timed", CHI, "2026-11-02T15:00:00Z", "2026-11-02T16:00:00Z", False),
    ],
}

Path(sys.argv[1] if len(sys.argv) > 1 else "packages/shared-config/date-time-fixtures.json").write_text(
    json.dumps(fixtures, indent=2) + "\n")

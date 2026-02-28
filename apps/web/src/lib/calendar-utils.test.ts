import { describe, it, expect } from 'vitest';
import { generateICS, generateGoogleCalendarUrl } from './calendar-utils';

describe('generateICS', () => {
	const baseParams = {
		title: 'Team Standup',
		startTime: '2025-03-15T10:00:00Z',
		endTime: '2025-03-15T10:30:00Z'
	};

	it('generates valid iCalendar content with required fields', () => {
		const ics = generateICS(baseParams);

		expect(ics).toContain('BEGIN:VCALENDAR');
		expect(ics).toContain('END:VCALENDAR');
		expect(ics).toContain('BEGIN:VEVENT');
		expect(ics).toContain('END:VEVENT');
		expect(ics).toContain('VERSION:2.0');
		expect(ics).toContain('PRODID:-//Meeting Scheduler//EN');
		expect(ics).toContain('CALSCALE:GREGORIAN');
		expect(ics).toContain('METHOD:PUBLISH');
	});

	it('formats start and end times in iCal format', () => {
		const ics = generateICS(baseParams);

		expect(ics).toContain('DTSTART:20250315T100000Z');
		expect(ics).toContain('DTEND:20250315T103000Z');
	});

	it('includes SUMMARY with title', () => {
		const ics = generateICS(baseParams);
		expect(ics).toContain('SUMMARY:Team Standup');
	});

	it('includes DESCRIPTION when provided', () => {
		const ics = generateICS({
			...baseParams,
			description: 'Daily sync meeting'
		});

		expect(ics).toContain('DESCRIPTION:Daily sync meeting');
	});

	it('excludes DESCRIPTION when not provided', () => {
		const ics = generateICS(baseParams);
		expect(ics).not.toContain('DESCRIPTION:');
	});

	it('includes LOCATION when provided', () => {
		const ics = generateICS({
			...baseParams,
			location: 'Conference Room A'
		});

		expect(ics).toContain('LOCATION:Conference Room A');
	});

	it('excludes LOCATION when not provided', () => {
		const ics = generateICS(baseParams);
		expect(ics).not.toContain('LOCATION:');
	});

	it('escapes special characters in title', () => {
		const ics = generateICS({
			...baseParams,
			title: 'Meeting; with, special\\chars'
		});

		expect(ics).toContain('SUMMARY:Meeting\\; with\\, special\\\\chars');
	});

	it('escapes newlines in description', () => {
		const ics = generateICS({
			...baseParams,
			description: 'Line 1\nLine 2'
		});

		expect(ics).toContain('DESCRIPTION:Line 1\\nLine 2');
	});

	it('uses CRLF line endings per iCal spec', () => {
		const ics = generateICS(baseParams);
		expect(ics).toContain('\r\n');
		// Should not have standalone LF (except inside escaped content)
		const lines = ics.split('\r\n');
		expect(lines.length).toBeGreaterThan(1);
	});

	it('includes STATUS:CONFIRMED', () => {
		const ics = generateICS(baseParams);
		expect(ics).toContain('STATUS:CONFIRMED');
	});

	it('includes UID with meetingscheduler.app domain', () => {
		const ics = generateICS(baseParams);
		expect(ics).toMatch(/UID:\d+@meetingscheduler\.app/);
	});

	it('handles different timezones in ISO strings', () => {
		const ics = generateICS({
			...baseParams,
			startTime: '2025-06-20T14:30:00.000Z',
			endTime: '2025-06-20T15:00:00.000Z'
		});

		expect(ics).toContain('DTSTART:20250620T143000Z');
		expect(ics).toContain('DTEND:20250620T150000Z');
	});

	it('includes both description and location when both provided', () => {
		const ics = generateICS({
			...baseParams,
			description: 'Important meeting',
			location: 'Room 42'
		});

		expect(ics).toContain('DESCRIPTION:Important meeting');
		expect(ics).toContain('LOCATION:Room 42');
	});
});

describe('generateGoogleCalendarUrl', () => {
	const baseParams = {
		title: 'Team Standup',
		startTime: '2025-03-15T10:00:00Z',
		endTime: '2025-03-15T10:30:00Z'
	};

	it('generates a Google Calendar URL', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		expect(url).toContain('https://calendar.google.com/calendar/render?');
	});

	it('includes action=TEMPLATE parameter', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		expect(url).toContain('action=TEMPLATE');
	});

	it('includes the title as text parameter', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('text')).toBe('Team Standup');
	});

	it('formats dates correctly in the dates parameter', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		const parsedUrl = new URL(url);
		const dates = parsedUrl.searchParams.get('dates');
		expect(dates).toBe('20250315T100000Z/20250315T103000Z');
	});

	it('includes details when description is provided', () => {
		const url = generateGoogleCalendarUrl({
			...baseParams,
			description: 'Daily sync'
		});
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('details')).toBe('Daily sync');
	});

	it('excludes details when description is not provided', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('details')).toBeNull();
	});

	it('includes location when provided', () => {
		const url = generateGoogleCalendarUrl({
			...baseParams,
			location: 'Office'
		});
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('location')).toBe('Office');
	});

	it('excludes location when not provided', () => {
		const url = generateGoogleCalendarUrl(baseParams);
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('location')).toBeNull();
	});

	it('properly encodes special characters in title', () => {
		const url = generateGoogleCalendarUrl({
			...baseParams,
			title: 'Meeting & Planning'
		});
		const parsedUrl = new URL(url);
		expect(parsedUrl.searchParams.get('text')).toBe('Meeting & Planning');
	});
});

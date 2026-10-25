/**
 * Calendar utilities for generating calendar event files
 */
import { addDays, allDayDate } from './date-time';

export interface CalendarEventTimes {
	startTime: string; // ISO instant
	endTime: string; // ISO instant
	isAllDay?: boolean;
	timezone?: string; // Poll zone; required to place an all-day date
}

/**
 * Formats a date for iCalendar format (YYYYMMDDTHHMMSSZ in UTC)
 */
function formatICalDate(date: Date): string {
	const year = date.getUTCFullYear();
	const month = String(date.getUTCMonth() + 1).padStart(2, '0');
	const day = String(date.getUTCDate()).padStart(2, '0');
	const hours = String(date.getUTCHours()).padStart(2, '0');
	const minutes = String(date.getUTCMinutes()).padStart(2, '0');
	const seconds = String(date.getUTCSeconds()).padStart(2, '0');
	return `${year}${month}${day}T${hours}${minutes}${seconds}Z`;
}

/**
 * DTSTART/DTEND values. An all-day option is one calendar date in the poll's
 * zone, exported as a floating DATE with an exclusive next-day end.
 */
export function eventDates({ startTime, endTime, isAllDay, timezone }: CalendarEventTimes): { start: string; end: string; allDay: boolean } {
	if (isAllDay && timezone) {
		const date = allDayDate({ start_time: startTime }, timezone);
		return { start: date.replaceAll('-', ''), end: addDays(date, 1).replaceAll('-', ''), allDay: true };
	}
	return { start: formatICalDate(new Date(startTime)), end: formatICalDate(new Date(endTime)), allDay: false };
}

/**
 * Escapes text for iCalendar format
 */
function escapeICalText(text: string): string {
	return text.replace(/[\\,;]/g, '\\$&').replace(/\n/g, '\\n');
}

/**
 * Generates an ICS (iCalendar) file for a meeting
 */
export function generateICS(params: CalendarEventTimes & {
	title: string;
	description?: string;
	location?: string;
}): string {
	const { title, description, location } = params;
	const dates = eventDates(params);
	const now = new Date();

	const icsContent = [
		'BEGIN:VCALENDAR',
		'VERSION:2.0',
		'PRODID:-//Meeting Scheduler//EN',
		'CALSCALE:GREGORIAN',
		'METHOD:PUBLISH',
		'BEGIN:VEVENT',
		dates.allDay ? `DTSTART;VALUE=DATE:${dates.start}` : `DTSTART:${dates.start}`,
		dates.allDay ? `DTEND;VALUE=DATE:${dates.end}` : `DTEND:${dates.end}`,
		`DTSTAMP:${formatICalDate(now)}`,
		`UID:${Date.now()}@meetingscheduler.app`,
		`SUMMARY:${escapeICalText(title)}`,
		description ? `DESCRIPTION:${escapeICalText(description)}` : null,
		location ? `LOCATION:${escapeICalText(location)}` : null,
		'STATUS:CONFIRMED',
		'SEQUENCE:0',
		'END:VEVENT',
		'END:VCALENDAR'
	]
		.filter((line) => line !== null)
		.join('\r\n');

	return icsContent;
}

/**
 * Downloads an ICS file
 */
export function downloadICS(icsContent: string, filename: string = 'meeting.ics'): void {
	const blob = new Blob([icsContent], { type: 'text/calendar;charset=utf-8' });
	const url = URL.createObjectURL(blob);
	const link = document.createElement('a');
	link.href = url;
	link.download = filename;
	document.body.appendChild(link);
	link.click();
	document.body.removeChild(link);
	URL.revokeObjectURL(url);
}

/**
 * Generates a Google Calendar URL
 */
export function generateGoogleCalendarUrl(params: CalendarEventTimes & {
	title: string;
	description?: string;
	location?: string;
}): string {
	const { title, description, location } = params;
	const dates = eventDates(params);

	// Google Calendar uses YYYYMMDDTHHmmssZ, or YYYYMMDD with an exclusive end for all-day events.
	const params_obj = new URLSearchParams({
		action: 'TEMPLATE',
		text: title,
		dates: `${dates.start}/${dates.end}`,
		...(description && { details: description }),
		...(location && { location })
	});

	return `https://calendar.google.com/calendar/render?${params_obj.toString()}`;
}

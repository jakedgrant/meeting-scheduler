/**
 * Calendar utilities for generating calendar event files
 */

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
 * Escapes text for iCalendar format
 */
function escapeICalText(text: string): string {
	return text.replace(/[\\,;]/g, '\\$&').replace(/\n/g, '\\n');
}

/**
 * Generates an ICS (iCalendar) file for a meeting
 */
export function generateICS(params: {
	title: string;
	description?: string;
	location?: string;
	startTime: string; // ISO date string
	endTime: string; // ISO date string
}): string {
	const { title, description, location, startTime, endTime } = params;

	const startDate = new Date(startTime);
	const endDate = new Date(endTime);
	const now = new Date();

	const icsContent = [
		'BEGIN:VCALENDAR',
		'VERSION:2.0',
		'PRODID:-//Meeting Scheduler//EN',
		'CALSCALE:GREGORIAN',
		'METHOD:PUBLISH',
		'BEGIN:VEVENT',
		`DTSTART:${formatICalDate(startDate)}`,
		`DTEND:${formatICalDate(endDate)}`,
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
export function generateGoogleCalendarUrl(params: {
	title: string;
	description?: string;
	location?: string;
	startTime: string; // ISO date string
	endTime: string; // ISO date string
}): string {
	const { title, description, location, startTime, endTime } = params;

	const startDate = new Date(startTime);
	const endDate = new Date(endTime);

	// Google Calendar uses format: YYYYMMDDTHHmmssZ
	const formatGoogleDate = (date: Date) => formatICalDate(date).replace(/[-:]/g, '');

	const params_obj = new URLSearchParams({
		action: 'TEMPLATE',
		text: title,
		dates: `${formatGoogleDate(startDate)}/${formatGoogleDate(endDate)}`,
		...(description && { details: description }),
		...(location && { location })
	});

	return `https://calendar.google.com/calendar/render?${params_obj.toString()}`;
}

// Display formatting for times and dates. Times that belong to the senior's
// day are shown in the senior's time zone. No imports, so it runs under plain
// Node for tests.

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(key: string, options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  let f = formatters.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat('en-CA', options);
    formatters.set(key, f);
  }
  return f;
}

/** "9:05 a.m." style clock time of an instant, in `timeZone`. */
export function formatTime(date: Date, timeZone: string): string {
  return formatter('time|' + timeZone, { timeZone, hour: 'numeric', minute: '2-digit' }).format(date);
}

/** "9:00 a.m." for a stored "09:00:00" time of day. */
export function formatTimeOfDay(value: string): string {
  const [h, m] = value.split(':').map(Number);
  return formatTime(new Date(Date.UTC(2000, 0, 1, h || 0, m || 0)), 'UTC');
}

/**
 * Canadian times end in "a.m."/"p.m.", so "at 4:53 p.m." + "." would read
 * "p.m.."; this drops the doubled period.
 */
export function tidy(text: string): string {
  return text.replace(/([ap])\.m\.\./g, '$1.m.');
}

/** "Thursday, October 16" */
export function formatDay(date: Date, timeZone: string): string {
  return formatter('day|' + timeZone, {
    timeZone,
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  }).format(date);
}

/** "Thu, Oct 16, 9:05 a.m." */
export function formatDateTime(date: Date, timeZone: string): string {
  return formatter('dt|' + timeZone, {
    timeZone,
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date);
}

/** "Eastern Time", falling back to the zone's id where names aren't available. */
export function timeZoneName(timeZone: string): string {
  try {
    const name = new Intl.DateTimeFormat('en-CA', { timeZone, timeZoneName: 'longGeneric' })
      .formatToParts(new Date())
      .find((p) => p.type === 'timeZoneName')?.value;
    return name || timeZone;
  } catch {
    return timeZone;
  }
}

export function deviceTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Toronto';
  } catch {
    return 'America/Toronto';
  }
}

/** "Good morning" / "Good afternoon" / "Good evening" for an hour 0-23. */
export function greeting(hour: number): string {
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

/** "Margaret", "Margaret and Alice", "Margaret, Alice and Bob" */
export function listNames(names: string[]): string {
  if (names.length <= 1) return names.join('');
  return names.slice(0, -1).join(', ') + ' and ' + names[names.length - 1];
}

export const DAY_NAMES = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;

export function frequencyLabel(frequency: string, dayOfWeek: number | null): string {
  switch (frequency) {
    case 'weekdays':
      return 'Weekdays';
    case 'weekends':
      return 'Weekends';
    case 'weekly':
      return 'Every ' + DAY_NAMES[dayOfWeek ?? 1];
    default:
      return 'Every day';
  }
}

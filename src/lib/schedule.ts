// Check-in timing, ported from the original prototype. All "today" maths runs
// in the senior's time zone, so a family member in another province sees the
// same check-in times the senior does. No imports, so it runs under plain
// Node for tests (src/lib/schedule.test.ts).

export type Frequency = 'daily' | 'weekdays' | 'weekends' | 'weekly';

export type Schedule = {
  id: string;
  label: string;
  /** "HH:MM" or "HH:MM:SS", in the senior's time zone. */
  time_of_day: string;
  frequency: Frequency;
  /** 0 = Sunday ... 6 = Saturday; used when frequency is weekly. */
  day_of_week: number | null;
  is_active: boolean;
};

export type CheckinStatus = 'ok' | 'need_help' | 'no_response';

export type Checkin = {
  id: string;
  status: CheckinStatus;
  occurred_at: string;
  schedule_id: string | null;
  scheduled_for: string | null;
  message: string | null;
};

const HOUR = 3600e3;
/** Checking in up to two hours before a time counts for it. */
export const EARLY_MS = 2 * HOUR;
/** A check-in is overdue an hour after its time. */
export const GRACE_MS = HOUR;
/** A response up to four hours after a time still counts for it. */
export const COVER_AFTER_MS = 4 * HOUR;

export type ZonedParts = {
  year: number;
  month: number;
  day: number;
  /** 0 = Sunday ... 6 = Saturday */
  weekday: number;
  hour: number;
  minute: number;
};

const WEEKDAYS: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
const partsFormatters = new Map<string, Intl.DateTimeFormat>();

/** The calendar date and wall-clock time of `date` in `timeZone`. */
export function zonedParts(date: Date, timeZone: string): ZonedParts {
  let fmt = partsFormatters.get(timeZone);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hour12: false,
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      weekday: 'short',
    });
    partsFormatters.set(timeZone, fmt);
  }
  const parts = fmt.formatToParts(date);
  const value = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return {
    year: Number(value('year')),
    month: Number(value('month')),
    day: Number(value('day')),
    weekday: WEEKDAYS[value('weekday')] ?? 0,
    hour: Number(value('hour')) % 24,
    minute: Number(value('minute')),
  };
}

/** Milliseconds `timeZone` is ahead of UTC at `date` (negative in the Americas). */
function offsetMs(date: Date, timeZone: string): number {
  const p = zonedParts(date, timeZone);
  const wall = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
  return wall - Math.floor(date.getTime() / 60e3) * 60e3;
}

/** The instant a wall-clock time happens in `timeZone`. */
export function zonedTimeToDate(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  timeZone: string,
): Date {
  const wall = Date.UTC(year, month - 1, day, hour, minute);
  let t = wall - offsetMs(new Date(wall), timeZone);
  // Around a daylight-saving change the first guess can be an hour off.
  const corrected = wall - offsetMs(new Date(t), timeZone);
  if (corrected !== t) t = corrected;
  return new Date(t);
}

export function parseTimeOfDay(value: string): { hour: number; minute: number } {
  const [h, m] = value.split(':').map(Number);
  return { hour: h || 0, minute: m || 0 };
}

export function occursOn(s: Pick<Schedule, 'frequency' | 'day_of_week'>, weekday: number): boolean {
  switch (s.frequency) {
    case 'weekdays':
      return weekday >= 1 && weekday <= 5;
    case 'weekends':
      return weekday === 0 || weekday === 6;
    case 'weekly':
      return weekday === (s.day_of_week ?? 1);
    default:
      return true;
  }
}

export type Occurrence = { schedule: Schedule; at: Date };

/** Today's active check-in times, earliest first. "Today" is the senior's day. */
export function todaysOccurrences(schedules: Schedule[], now: Date, timeZone: string): Occurrence[] {
  const today = zonedParts(now, timeZone);
  return schedules
    .filter((s) => s.is_active && occursOn(s, today.weekday))
    .map((schedule) => {
      const { hour, minute } = parseTimeOfDay(schedule.time_of_day);
      return {
        schedule,
        at: zonedTimeToDate(today.year, today.month, today.day, hour, minute, timeZone),
      };
    })
    .sort((a, b) => a.at.getTime() - b.at.getTime());
}

export type OccurrenceState =
  | { kind: 'done'; checkin: Checkin }
  | { kind: 'missed' }
  | { kind: 'upcoming' }
  | { kind: 'due' }
  | { kind: 'late' };

export function occurrenceState(o: Occurrence, checkins: Checkin[], now: Date): OccurrenceState {
  const t = o.at.getTime();
  const from = t - EARLY_MS;
  const to = t + COVER_AFTER_MS;
  const responses = checkins
    .filter((c) => c.status !== 'no_response')
    .filter((c) => {
      const at = new Date(c.occurred_at).getTime();
      return at >= from && at <= to;
    })
    .sort((a, b) => new Date(b.occurred_at).getTime() - new Date(a.occurred_at).getTime());
  if (responses[0]) return { kind: 'done', checkin: responses[0] };

  const missed = checkins.some(
    (c) =>
      c.status === 'no_response' &&
      c.schedule_id === o.schedule.id &&
      c.scheduled_for !== null &&
      Math.abs(new Date(c.scheduled_for).getTime() - t) < 60e3,
  );
  if (missed) return { kind: 'missed' };

  const n = now.getTime();
  if (n < from) return { kind: 'upcoming' };
  if (n <= t + GRACE_MS) return { kind: 'due' };
  return { kind: 'late' };
}

/** The check-in time a response right now would count for, if any. */
export function currentOccurrence(occurrences: Occurrence[], now: Date): Occurrence | null {
  const n = now.getTime();
  const open = occurrences.filter(
    (o) => n >= o.at.getTime() - EARLY_MS && n <= o.at.getTime() + COVER_AFTER_MS,
  );
  open.sort((a, b) => Math.abs(n - a.at.getTime()) - Math.abs(n - b.at.getTime()));
  return open[0] ?? null;
}

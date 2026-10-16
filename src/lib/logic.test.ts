/// <reference types="node" />
// Run with: npm test
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { formatTimeOfDay, frequencyLabel, listNames, tidy } from './format.ts';
import {
  currentOccurrence,
  occurrenceState,
  todaysOccurrences,
  zonedParts,
  zonedTimeToDate,
  type Checkin,
  type Schedule,
} from './schedule.ts';
import { formatPhone, normalizeEmail, normalizePhone, parseSignInTarget } from './sign-in-target.ts';

const TO = 'America/Toronto';

function schedule(over: Partial<Schedule> = {}): Schedule {
  return {
    id: 's1',
    label: 'Morning',
    time_of_day: '09:00:00',
    frequency: 'daily',
    day_of_week: null,
    is_active: true,
    ...over,
  };
}

function checkin(over: Partial<Checkin>): Checkin {
  return {
    id: 'c' + Math.random(),
    status: 'ok',
    occurred_at: new Date().toISOString(),
    schedule_id: null,
    scheduled_for: null,
    message: null,
    ...over,
  };
}

describe('time zones', () => {
  test('wall-clock time to instant, summer and winter', () => {
    assert.equal(zonedTimeToDate(2026, 7, 1, 9, 0, TO).toISOString(), '2026-07-01T13:00:00.000Z');
    assert.equal(zonedTimeToDate(2026, 12, 1, 9, 0, TO).toISOString(), '2026-12-01T14:00:00.000Z');
    assert.equal(
      zonedTimeToDate(2026, 12, 1, 9, 0, 'America/Vancouver').toISOString(),
      '2026-12-01T17:00:00.000Z',
    );
  });

  test('the day daylight saving ends (Nov 1, 2026)', () => {
    // Clocks fall back at 2 a.m.; 9 a.m. that day is already standard time.
    assert.equal(zonedTimeToDate(2026, 11, 1, 9, 0, TO).toISOString(), '2026-11-01T14:00:00.000Z');
    assert.equal(zonedTimeToDate(2026, 11, 1, 0, 30, TO).toISOString(), '2026-11-01T04:30:00.000Z');
  });

  test("today is the senior's today, not the viewer's", () => {
    // 11:30 p.m. Thursday in Vancouver is already Friday in Toronto... and the
    // other way round: 1 a.m. Friday UTC is still Thursday evening in Toronto.
    const p = zonedParts(new Date('2026-10-16T01:00:00Z'), TO);
    assert.deepEqual([p.year, p.month, p.day, p.weekday, p.hour], [2026, 10, 15, 4, 21]);
  });
});

describe('todays occurrences', () => {
  const thursday = new Date('2026-10-15T12:00:00Z'); // 8 a.m. Thursday in Toronto

  test('frequency rules', () => {
    const list = todaysOccurrences(
      [
        schedule({ id: 'daily' }),
        schedule({ id: 'weekdays', frequency: 'weekdays' }),
        schedule({ id: 'weekends', frequency: 'weekends' }),
        schedule({ id: 'thu', frequency: 'weekly', day_of_week: 4 }),
        schedule({ id: 'fri', frequency: 'weekly', day_of_week: 5 }),
        schedule({ id: 'paused', is_active: false }),
      ],
      thursday,
      TO,
    );
    assert.deepEqual(
      list.map((o) => o.schedule.id),
      ['daily', 'weekdays', 'thu'],
    );
  });

  test('sorted by time and placed in the right zone', () => {
    const list = todaysOccurrences(
      [schedule({ id: 'eve', time_of_day: '19:30:00' }), schedule({ id: 'am', time_of_day: '08:15' })],
      thursday,
      TO,
    );
    assert.deepEqual(
      list.map((o) => [o.schedule.id, o.at.toISOString()]),
      [
        ['am', '2026-10-15T12:15:00.000Z'],
        ['eve', '2026-10-15T23:30:00.000Z'],
      ],
    );
  });
});

describe('occurrence state', () => {
  const nine = { schedule: schedule(), at: new Date('2026-10-15T13:00:00Z') };
  const at = (iso: string) => new Date(iso);

  test('upcoming, due, late', () => {
    assert.equal(occurrenceState(nine, [], at('2026-10-15T10:59:00Z')).kind, 'upcoming');
    assert.equal(occurrenceState(nine, [], at('2026-10-15T11:00:00Z')).kind, 'due'); // 2h early
    assert.equal(occurrenceState(nine, [], at('2026-10-15T14:00:00Z')).kind, 'due'); // 1h grace
    assert.equal(occurrenceState(nine, [], at('2026-10-15T14:01:00Z')).kind, 'late');
  });

  test('a response from 2h before to 4h after counts', () => {
    const now = at('2026-10-15T20:00:00Z');
    const early = checkin({ occurred_at: '2026-10-15T11:00:00Z' });
    const tooEarly = checkin({ occurred_at: '2026-10-15T10:59:00Z' });
    const lateButCounts = checkin({ occurred_at: '2026-10-15T17:00:00Z' });
    assert.equal(occurrenceState(nine, [early], now).kind, 'done');
    assert.equal(occurrenceState(nine, [tooEarly], now).kind, 'late');
    assert.equal(occurrenceState(nine, [lateButCounts], now).kind, 'done');
  });

  test('help requests count as a response; the latest one is shown', () => {
    const ok = checkin({ id: 'ok', occurred_at: '2026-10-15T12:50:00Z' });
    const help = checkin({ id: 'help', status: 'need_help', occurred_at: '2026-10-15T13:10:00Z' });
    const state = occurrenceState(nine, [ok, help], at('2026-10-15T13:20:00Z'));
    assert.equal(state.kind === 'done' && state.checkin.id, 'help');
  });

  test('a missed check-in recorded by the server', () => {
    const missed = checkin({
      status: 'no_response',
      schedule_id: 's1',
      scheduled_for: '2026-10-15T13:00:00Z',
    });
    assert.equal(occurrenceState(nine, [missed], at('2026-10-15T14:10:00Z')).kind, 'missed');
  });

  test('current occurrence is the nearest open one', () => {
    const list = [
      nine,
      { schedule: schedule({ id: 's2' }), at: new Date('2026-10-15T23:00:00Z') },
    ];
    assert.equal(currentOccurrence(list, at('2026-10-15T12:00:00Z'))?.schedule.id, 's1');
    assert.equal(currentOccurrence(list, at('2026-10-15T21:30:00Z'))?.schedule.id, 's2');
    assert.equal(currentOccurrence(list, at('2026-10-15T18:00:00Z')), null);
  });
});

describe('formatting', () => {
  test('times of day and lists', () => {
    assert.match(formatTimeOfDay('09:00:00'), /^9:00\sa\.m\.$/);
    assert.match(formatTimeOfDay('19:30'), /^7:30\sp\.m\.$/);
    assert.equal(frequencyLabel('weekly', 3), 'Every Wednesday');
    assert.equal(listNames(['Ann', 'Bo', 'Cy']), 'Ann, Bo and Cy');
  });

  test('no doubled period after a.m./p.m.', () => {
    assert.equal(tidy('Checked in at 4:53 p.m.. Next at 9:00 a.m..'), 'Checked in at 4:53 p.m. Next at 9:00 a.m.');
    assert.equal(tidy('All done.'), 'All done.');
  });
});

describe('phones and emails', () => {
  test('normalises North American numbers', () => {
    assert.equal(normalizePhone('613-555-0123'), '+16135550123');
    assert.equal(normalizePhone('(613) 555 0123'), '+16135550123');
    assert.equal(normalizePhone('1 613 555 0123'), '+16135550123');
    assert.equal(normalizePhone('+44 20 7946 0958'), '+442079460958');
    assert.equal(normalizePhone('555-0123'), null);
    assert.equal(normalizePhone('call me'), null);
    assert.equal(formatPhone('+16135550123'), '(613) 555-0123');
  });

  test('emails and sign-in targets', () => {
    assert.equal(normalizeEmail('  Alice@Example.COM '), 'alice@example.com');
    assert.equal(normalizeEmail('alice@'), null);
    assert.deepEqual(parseSignInTarget('613.555.0123'), { kind: 'phone', phone: '+16135550123' });
    assert.equal(parseSignInTarget('not an email'), null);
  });
});

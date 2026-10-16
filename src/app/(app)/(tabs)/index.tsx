import { useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import { TodayList } from '@/components/today';
import { Button, Card, Field, Label, Message, Screen } from '@/components/ui';
import { ALERTS_LIVE } from '@/constants/features';
import { FontSize, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useCircle, type CircleData } from '@/lib/circle';
import {
  deviceTimeZone,
  formatDay,
  formatTime,
  greeting,
  listNames,
  tidy,
  timeZoneName,
} from '@/lib/format';
import {
  currentOccurrence,
  occurrenceState,
  todaysOccurrences,
  zonedParts,
  type Occurrence,
} from '@/lib/schedule';
import { formatPhone } from '@/lib/sign-in-target';
import { supabase } from '@/lib/supabase';

/** The current time, ticking every minute so statuses move from "Later" to "Now". */
function useNow() {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 60e3);
    return () => clearInterval(t);
  }, []);
  return now;
}

export default function TodayScreen() {
  const circle = useCircle();
  const now = useNow();
  const { refresh } = circle;
  useFocusEffect(
    useCallback(() => {
      refresh();
    }, [refresh]),
  );
  const occurrences = todaysOccurrences(circle.schedules, now, circle.senior.timezone);
  return circle.role === 'senior' ? (
    <CheckInView circle={circle} now={now} occurrences={occurrences} />
  ) : (
    <FamilyView circle={circle} now={now} occurrences={occurrences} />
  );
}

type ViewProps = {
  circle: CircleData & { refresh: () => Promise<void> };
  now: Date;
  occurrences: Occurrence[];
};

// ---------------------------------------------------------------------------
// The senior's screen
// ---------------------------------------------------------------------------

type Stage = 'ask' | 'confirm' | 'ok' | 'help';

function CheckInView({ circle, now, occurrences }: ViewProps) {
  const c = useTheme();
  const { senior, checkins, contacts, refresh } = circle;
  const tz = senior.timezone;
  const [stage, setStage] = useState<Stage>('ask');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [savedAt, setSavedAt] = useState<Date | null>(null);

  async function save(status: 'ok' | 'need_help') {
    setBusy(true);
    setError('');
    const o = currentOccurrence(occurrences, new Date());
    const { error } = await supabase.from('checkins').insert({
      senior_id: senior.id,
      status,
      message: note.trim() || null,
      schedule_id: o?.schedule.id ?? null,
      scheduled_for: o?.at.toISOString() ?? null,
    });
    setBusy(false);
    if (error) {
      setError(
        status === 'need_help'
          ? "Your help request didn't save. Please call 911 or a family member."
          : "That didn't save. Check your internet connection and try again.",
      );
      return;
    }
    setNote('');
    setSavedAt(new Date());
    setStage(status === 'ok' ? 'ok' : 'help');
    refresh();
  }

  const hour = zonedParts(now, tz).hour;
  const routine = contacts.filter((x) => x.notify_on_checkin);

  return (
    <Screen onRefresh={refresh}>
      <View style={styles.header}>
        <Label variant="small">{formatDay(now, tz)}</Label>
        <Label variant="title">
          {greeting(hour)}, {senior.first_name}
        </Label>
        <Label>{tidy(statusLine(circle, now, occurrences))}</Label>
      </View>

      {stage === 'ask' ? (
        <View style={styles.ask}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="I'm OK"
            accessibilityHint="Lets your family know you're OK"
            disabled={busy}
            onPress={() => save('ok')}
            style={({ pressed }) => [
              styles.okButton,
              { backgroundColor: c.ok, opacity: busy ? 0.6 : pressed ? 0.85 : 1 },
            ]}>
            <Text style={[styles.okText, { color: c.okText }]}>✓ I&apos;m OK</Text>
          </Pressable>
          <Field
            label="Add a note (optional)"
            placeholder="For example: going to the doctor this afternoon"
            value={note}
            onChangeText={setNote}
            multiline
            maxLength={1000}
          />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="I need help"
            disabled={busy}
            onPress={() => setStage('confirm')}
            style={({ pressed }) => [
              styles.helpButton,
              { borderColor: c.help, backgroundColor: c.surface, opacity: pressed ? 0.85 : 1 },
            ]}>
            <Text style={[styles.helpText, { color: c.help }]}>I need help</Text>
          </Pressable>
          <Message text={error} />
        </View>
      ) : null}

      {stage === 'confirm' ? (
        <Card tone="help">
          <Label variant="heading">Ask for help?</Label>
          <Label>
            {ALERTS_LIVE
              ? contacts.length
                ? `We'll alert ${listNames(contacts.map((x) => x.name))} right away.`
                : 'No one is listed under People yet, so no one can be alerted. Please call 911 or a family member.'
              : "Your family will see this in the app. It doesn't send them a text or email yet, so if you need help now, call 911 or phone a family member."}
          </Label>
          <Button title="Yes, I need help" kind="danger" onPress={() => save('need_help')} busy={busy} />
          <Button title="Cancel" kind="plain" onPress={() => setStage('ask')} disabled={busy} />
          <Message text={error} />
        </Card>
      ) : null}

      {stage === 'ok' ? (
        <Card tone="ok">
          <Label variant="heading">Thank you. You&apos;re checked in.</Label>
          <Label>
            {tidy(
              `Saved at ${savedAt ? formatTime(savedAt, tz) : ''}. ` +
                (ALERTS_LIVE && routine.length
                  ? `${listNames(routine.map((x) => x.name))} will get a message.`
                  : 'Your family can see it in the app.'),
            )}
          </Label>
          <Button title="Back to check-in" kind="plain" onPress={() => setStage('ask')} />
        </Card>
      ) : null}

      {stage === 'help' ? (
        <Card tone="help">
          <Label variant="heading">Your help request is saved.</Label>
          <Label>
            {ALERTS_LIVE
              ? "We're alerting your family now."
              : 'Your family can see it in the app, but it has not been sent to them.'}{' '}
            If you need help now, call 911 or phone a family member below.
          </Label>
          <Button title="Back to check-in" kind="plain" onPress={() => setStage('ask')} />
        </Card>
      ) : null}

      <TodayList
        occurrences={occurrences}
        checkins={checkins}
        now={now}
        timeZone={tz}
        hasSchedules={circle.schedules.length > 0}
      />

      <Emergency contacts={contacts} />
    </Screen>
  );
}

function statusLine({ schedules, checkins, senior }: CircleData, now: Date, occ: Occurrence[]): string {
  const tz = senior.timezone;
  if (!schedules.length) return 'You can check in any time. Check-in times can be added under Schedule.';
  const states = occ.map((o) => ({ o, s: occurrenceState(o, checkins, now) }));
  const due = states.find((x) => x.s.kind === 'due' || x.s.kind === 'late');
  const next = states.find((x) => x.s.kind === 'upcoming');
  const last = [...states].reverse().find((x) => x.s.kind === 'done');
  const lastAt =
    last && last.s.kind === 'done' ? formatTime(new Date(last.s.checkin.occurred_at), tz) : '';
  if (due) return `It's time for your ${due.o.schedule.label.toLowerCase()}. Please tap I'm OK.`;
  if (last && next) {
    return `You checked in at ${lastAt}. Next: ${next.o.schedule.label.toLowerCase()} at ${formatTime(next.o.at, tz)}.`;
  }
  if (last) return `You checked in at ${lastAt}. That's all for today.`;
  if (next) return `Your next check-in is at ${formatTime(next.o.at, tz)}.`;
  return 'No more check-ins today. You can still check in any time.';
}

function Emergency({ contacts }: { contacts: CircleData['contacts'] }) {
  const withPhone = contacts.filter((x) => x.phone);
  return (
    <Card tone="sunk">
      <Label variant="heading">In an emergency, call 911.</Label>
      <Button title="Call 911" kind="danger" onPress={() => Linking.openURL('tel:911')} />
      {withPhone.map((x) => (
        <Button
          key={x.id}
          kind="plain"
          title={`Call ${x.name}  ${formatPhone(x.phone!)}`}
          onPress={() => Linking.openURL('tel:' + x.phone)}
        />
      ))}
      <Label variant="small">Alive &amp; Well is not a medical alert service.</Label>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// The family's view
// ---------------------------------------------------------------------------

function FamilyView({ circle, now, occurrences }: ViewProps) {
  const { senior, checkins, schedules, refresh } = circle;
  const tz = senior.timezone;
  const name = senior.first_name;
  const today = zonedParts(now, tz);
  const isToday = (iso: string) => {
    const p = zonedParts(new Date(iso), tz);
    return p.year === today.year && p.month === today.month && p.day === today.day;
  };
  // Newest first, as loaded.
  const todays = checkins.filter((x) => x.status !== 'no_response' && isToday(x.occurred_at));
  const latest = todays[0];
  const help = latest?.status === 'need_help' ? latest : undefined;
  const earlierHelp = help ? undefined : todays.find((x) => x.status === 'need_help');
  const states = occurrences.map((o) => ({ o, s: occurrenceState(o, checkins, now) }));
  const overdue = states.find((x) => x.s.kind === 'late' || x.s.kind === 'missed');
  const next = states.find((x) => x.s.kind === 'upcoming' || x.s.kind === 'due');

  let tone: 'ok' | 'help' | 'late' | 'sunk' = 'sunk';
  let headline: string;
  if (help) {
    tone = 'help';
    headline = `${name} asked for help at ${formatTime(new Date(help.occurred_at), tz)}.`;
  } else if (overdue && (!latest || new Date(latest.occurred_at) < overdue.o.at)) {
    tone = 'late';
    headline = `${name} hasn't checked in for the ${overdue.o.schedule.label.toLowerCase()} (${formatTime(overdue.o.at, tz)}).`;
  } else if (latest) {
    tone = 'ok';
    headline = `${name} checked in at ${formatTime(new Date(latest.occurred_at), tz)}.`;
  } else if (!schedules.length) {
    headline = `${name} hasn't checked in today. Add check-in times under Schedule.`;
  } else if (next) {
    headline = `${name}'s next check-in is at ${formatTime(next.o.at, tz)}.`;
  } else {
    headline = `${name} hasn't checked in today.`;
  }
  const note = latest?.message;
  const otherZone = deviceTimeZone() !== tz;

  return (
    <Screen onRefresh={refresh}>
      <View style={styles.header}>
        <Label variant="small">
          {formatDay(now, tz)}
          {otherZone ? ` · times in ${timeZoneName(tz)}` : ''}
        </Label>
        <Label variant="title">{name} today</Label>
      </View>

      <Card tone={tone}>
        <Label variant="heading" accessibilityLiveRegion="polite">
          {tidy(headline)}
        </Label>
        {note ? <Label>“{note}”</Label> : null}
        {help ? <Label>Call them, or if you can&apos;t reach them, ask someone nearby to check in person.</Label> : null}
        {earlierHelp ? (
          <Label>
            Earlier, at {formatTime(new Date(earlierHelp.occurred_at), tz)}, {name} asked for help
            {earlierHelp.message ? `: “${earlierHelp.message}”` : '.'}
          </Label>
        ) : null}
      </Card>

      <TodayList
        occurrences={occurrences}
        checkins={checkins}
        now={now}
        timeZone={tz}
        hasSchedules={schedules.length > 0}
      />

      {!ALERTS_LIVE ? (
        <Label variant="small">
          Text and email alerts aren&apos;t switched on yet, so check this screen to see how {name} is
          doing. It updates every minute.
        </Label>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { gap: Spacing.xs },
  ask: { gap: Spacing.lg },
  okButton: {
    minHeight: 128,
    borderRadius: 24,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: Spacing.lg,
  },
  okText: { fontSize: 44, fontWeight: '800' },
  helpButton: {
    minHeight: 72,
    borderRadius: 18,
    borderWidth: 3,
    alignItems: 'center',
    justifyContent: 'center',
  },
  helpText: { fontSize: FontSize.large + 4, fontWeight: '800' },
});

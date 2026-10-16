import { StyleSheet, Text, View } from 'react-native';

import { Card, Label, Pill, type PillTone } from '@/components/ui';
import { FontSize, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { formatTime } from '@/lib/format';
import { occurrenceState, type Checkin, type Occurrence, type OccurrenceState } from '@/lib/schedule';

export function statePill(state: OccurrenceState, timeZone: string): { text: string; tone: PillTone } {
  switch (state.kind) {
    case 'done': {
      const at = formatTime(new Date(state.checkin.occurred_at), timeZone);
      return state.checkin.status === 'need_help'
        ? { text: 'Help asked ' + at, tone: 'help' }
        : { text: 'Done ' + at, tone: 'ok' };
    }
    case 'missed':
      return { text: 'Missed', tone: 'late' };
    case 'late':
      return { text: 'Overdue', tone: 'late' };
    case 'due':
      return { text: 'Now', tone: 'wait' };
    default:
      return { text: 'Later', tone: 'wait' };
  }
}

/** Today's check-in times with how each one went. */
export function TodayList({
  occurrences,
  checkins,
  now,
  timeZone,
  hasSchedules,
}: {
  occurrences: Occurrence[];
  checkins: Checkin[];
  now: Date;
  timeZone: string;
  hasSchedules: boolean;
}) {
  const c = useTheme();
  return (
    <Card>
      <Label variant="heading">Today&apos;s check-ins</Label>
      {occurrences.length === 0 ? (
        <Label variant="muted">
          {hasSchedules
            ? 'No check-ins scheduled today.'
            : 'No check-in times set yet. Add them under Schedule.'}
        </Label>
      ) : (
        occurrences.map((o) => {
          const pill = statePill(occurrenceState(o, checkins, now), timeZone);
          return (
            <View
              key={o.schedule.id}
              style={styles.row}
              accessible
              accessibilityLabel={`${o.schedule.label} at ${formatTime(o.at, timeZone)}: ${pill.text}`}>
              <View style={styles.main}>
                <Text style={[styles.time, { color: c.text }]}>{formatTime(o.at, timeZone)}</Text>
                <Label variant="muted">{o.schedule.label}</Label>
              </View>
              <Pill text={pill.text} tone={pill.tone} />
            </View>
          );
        })
      )}
    </Card>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: Spacing.md },
  main: { flex: 1 },
  time: { fontSize: FontSize.large, fontWeight: '700', fontVariant: ['tabular-nums'] },
});

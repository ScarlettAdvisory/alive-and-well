import { router } from 'expo-router';

import { Button, Card, Label, Pill, Row, Screen } from '@/components/ui';
import { useCircle } from '@/lib/circle';
import { formatTimeOfDay, frequencyLabel, timeZoneName } from '@/lib/format';

export default function ScheduleScreen() {
  const { senior, schedules, refresh } = useCircle();
  return (
    <Screen onRefresh={refresh}>
      <Label variant="title">Check-in times</Label>
      <Label variant="muted">
        {senior.first_name} checks in at these times ({timeZoneName(senior.timezone)}). Checking in up
        to two hours early counts. A check-in is overdue an hour after its time.
      </Label>
      <Card>
        {schedules.length === 0 ? (
          <Label variant="muted">No check-in times yet. Add the first one below.</Label>
        ) : (
          schedules.map((s) => (
            <Row
              key={s.id}
              title={`${formatTimeOfDay(s.time_of_day)}  ${s.label}`}
              lines={[frequencyLabel(s.frequency, s.day_of_week)]}
              right={s.is_active ? undefined : <Pill text="Paused" tone="wait" />}
              hint="Opens this check-in time to change it"
              onPress={() => router.push({ pathname: '/schedule/[id]', params: { id: s.id } })}
            />
          ))
        )}
      </Card>
      <Button
        title="Add a check-in time"
        onPress={() => router.push({ pathname: '/schedule/[id]', params: { id: 'new' } })}
      />
    </Screen>
  );
}

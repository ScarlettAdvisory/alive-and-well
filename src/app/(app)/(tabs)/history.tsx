import { useFocusEffect } from 'expo-router';
import { useCallback } from 'react';

import { Card, Label, Pill, Row, Screen } from '@/components/ui';
import { alertsLive, alertWords } from '@/lib/alerts';
import { useCircle } from '@/lib/circle';
import { formatDateTime, formatTime } from '@/lib/format';

export default function HistoryScreen() {
  const { senior, checkins, alerts, refresh } = useCircle();
  const tz = senior.timezone;
  useFocusEffect(
    useCallback(() => {
      refresh();
    }, [refresh]),
  );

  return (
    <Screen onRefresh={refresh}>
      <Label variant="title">History</Label>
      <Card>
        {checkins.length === 0 ? (
          <Label variant="muted">No check-ins yet. They&apos;ll appear here after the first one.</Label>
        ) : (
          checkins.map((x) => {
            const pill =
              x.status === 'ok' ? (
                <Pill text="OK" tone="ok" />
              ) : x.status === 'need_help' ? (
                <Pill text="Needed help" tone="help" />
              ) : (
                <Pill text="Missed" tone="late" />
              );
            const when = new Date(x.status === 'no_response' && x.scheduled_for ? x.scheduled_for : x.occurred_at);
            return (
              <Row
                key={x.id}
                title={formatDateTime(when, tz)}
                lines={[
                  x.message && `“${x.message}”`,
                  x.status === 'no_response' && `No check-in by ${formatTime(new Date(x.occurred_at), tz)}`,
                ]}
                right={pill}
              />
            );
          })
        )}
      </Card>
      <Card tone="sunk">
        <Label variant="heading">How alerts work</Label>
        <Label>
          {alertsLive(alerts)
            ? `If ${senior.first_name} asks for help, or hasn't checked in an hour after a check-in time, everyone under People who can be reached gets ${alertWords(alerts)}, usually within a few minutes. Delivery depends on phone and email services, so it isn't guaranteed. In an emergency, call 911.`
            : "Text and email alerts aren't switched on yet. For now, family can see every check-in and help request here and on the Today screen. In an emergency, call 911."}
        </Label>
      </Card>
    </Screen>
  );
}

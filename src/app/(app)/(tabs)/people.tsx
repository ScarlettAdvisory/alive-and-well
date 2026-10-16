import { router } from 'expo-router';
import { useState } from 'react';

import { Button, Card, Label, Row, Screen } from '@/components/ui';
import { ALERTS_LIVE } from '@/constants/features';
import { useAuth } from '@/lib/auth';
import { useCircle } from '@/lib/circle';
import { timeZoneName } from '@/lib/format';
import { formatPhone } from '@/lib/sign-in-target';
import { supabase } from '@/lib/supabase';

export default function PeopleScreen() {
  const { session } = useAuth();
  const { senior, contacts, people, refresh } = useCircle();
  const [signingOut, setSigningOut] = useState(false);
  const me = session?.user.email || (session?.user.phone ? formatPhone('+' + session.user.phone.replace(/^\+/, '')) : '');

  return (
    <Screen onRefresh={refresh}>
      <Label variant="title">People</Label>

      <Card>
        <Label variant="heading">Who checks in</Label>
        <Row
          title={senior.first_name}
          lines={[`Check-in times use ${timeZoneName(senior.timezone)}`]}
          right={<Label variant="small">Change</Label>}
          hint="Change their name or time zone"
          onPress={() => router.push('/senior')}
        />
      </Card>

      <Card>
        <Label variant="heading">Family &amp; friends to alert</Label>
        <Label variant="small">
          {ALERTS_LIVE
            ? `Everyone here is alerted when a check-in is missed or ${senior.first_name} asks for help. Routine "I'm OK" messages go only to people who turn them on.`
            : `These are the people who will get texts and emails when alerts are switched on. Phone numbers here also appear as call buttons on ${senior.first_name}'s screen.`}
        </Label>
        {contacts.length === 0 ? (
          <Label variant="muted">No one added yet.</Label>
        ) : (
          contacts.map((x) => (
            <Row
              key={x.id}
              title={x.name}
              lines={[
                [x.relationship, x.phone && formatPhone(x.phone), x.email].filter(Boolean).join(' · '),
                x.notify_on_checkin ? 'Gets every check-in' : 'Alerts only',
              ]}
              right={<Label variant="small">Edit</Label>}
              hint={`Change or remove ${x.name}`}
              onPress={() => router.push({ pathname: '/contact/[id]', params: { id: x.id } })}
            />
          ))
        )}
        <Button
          title="Add a person"
          onPress={() => router.push({ pathname: '/contact/[id]', params: { id: 'new' } })}
        />
      </Card>

      <Card>
        <Label variant="heading">Using the app</Label>
        <Label variant="small">
          Everyone here can see check-ins and change these settings.
        </Label>
        {people.map((p) => (
          <Row
            key={p.user_id}
            title={(p.display_name || 'Someone') + (p.is_me ? ' (you)' : '')}
            lines={[p.role === 'senior' ? 'Checks in' : 'Family']}
          />
        ))}
        <Button title="Invite someone" kind="plain" onPress={() => router.push('/invite')} />
      </Card>

      <Card tone="sunk">
        <Label variant="heading">Your account</Label>
        {me ? <Label>Signed in as {me}</Label> : null}
        <Button
          title="Sign out"
          kind="plain"
          busy={signingOut}
          onPress={async () => {
            setSigningOut(true);
            await supabase.auth.signOut();
          }}
        />
      </Card>
    </Screen>
  );
}

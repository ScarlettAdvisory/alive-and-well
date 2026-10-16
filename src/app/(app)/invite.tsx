import { router } from 'expo-router';
import { useState } from 'react';
import { Platform, Share, StyleSheet, Text } from 'react-native';

import { Button, Card, Choices, Label, Message, Screen } from '@/components/ui';
import { useTheme } from '@/hooks/use-theme';
import { useCircle, type Role } from '@/lib/circle';
import { supabase } from '@/lib/supabase';

// Makes a one-time code another person types in after signing in, so they
// join this circle from their own phone.
export default function InviteScreen() {
  const c = useTheme();
  const { senior, people } = useCircle();
  const seniorHasApp = people.some((p) => p.role === 'senior');
  const [role, setRole] = useState<Role>(seniorHasApp ? 'family' : 'senior');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function makeCode() {
    setBusy(true);
    setError('');
    const { data, error } = await supabase.rpc('create_invite', {
      p_senior_id: senior.id,
      p_role: role,
    });
    setBusy(false);
    if (error || typeof data !== 'string') {
      return setError("We couldn't make a code. Check your internet connection and try again.");
    }
    setCode(data);
  }

  const pretty = code ? code.slice(0, 4) + ' ' + code.slice(4) : '';
  const message =
    `Join ${senior.first_name}'s check-ins on Alive & Well. ` +
    `Sign in to the app, choose "I have an invite code" and enter: ${pretty}. ` +
    'The code works once and expires in 7 days.';

  return (
    <Screen>
      <Label variant="title">Invite someone</Label>
      {!code ? (
        <>
          <Choices
            label="Who is it for?"
            value={role}
            onChange={setRole}
            options={[
              { value: 'senior', label: `${senior.first_name}, on their own phone` },
              { value: 'family', label: 'Another family member' },
            ]}
          />
          <Label variant="muted">
            {role === 'senior'
              ? `${senior.first_name} will see the check-in buttons.`
              : 'They will see how check-ins are going and can change settings.'}
          </Label>
          <Message text={error} />
          <Button title="Make an invite code" onPress={makeCode} busy={busy} />
        </>
      ) : (
        <Card tone="ok">
          <Label>Give them this code:</Label>
          <Text
            selectable
            accessibilityLabel={'Invite code ' + code.split('').join(' ')}
            style={[styles.code, { color: c.text }]}>
            {pretty}
          </Text>
          <Label variant="small">
            They sign in to Alive &amp; Well, choose “I have an invite code” and type it in. It works
            once and expires in 7 days.
          </Label>
          {Platform.OS !== 'web' ? (
            <Button title="Send it in a message" onPress={() => Share.share({ message })} />
          ) : null}
        </Card>
      )}
      <Button title={code ? 'Done' : 'Cancel'} kind="plain" onPress={() => router.back()} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  code: { fontSize: 44, fontWeight: '800', letterSpacing: 4, textAlign: 'center', fontVariant: ['tabular-nums'] },
});

import { useState } from 'react';

import { Button, Choices, Field, Label, Message, Screen } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { useCircleState } from '@/lib/circle';
import { deviceTimeZone, timeZoneName } from '@/lib/format';
import { supabase } from '@/lib/supabase';

type Path = 'me' | 'family' | 'invite';

// Shown once, right after someone first signs in and isn't part of a circle.
export default function WelcomeScreen() {
  const { session } = useAuth();
  const { refresh } = useCircleState();
  const [myName, setMyName] = useState('');
  const [path, setPath] = useState<Path>('me');
  const [seniorName, setSeniorName] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const timeZone = deviceTimeZone();

  async function onContinue() {
    setError('');
    const name = myName.trim();
    if (!name) return setError('Please enter your first name.');
    if (path === 'family' && !seniorName.trim()) {
      return setError('Please enter the first name of the person who will check in.');
    }
    if (path === 'invite' && code.replace(/[^A-Za-z0-9]/g, '').length !== 8) {
      return setError('Invite codes are 8 letters and numbers. Check the code and try again.');
    }

    const userId = session?.user.id;
    if (!userId) return;
    setBusy(true);
    const { error: nameError } = await supabase
      .from('profiles')
      .update({ display_name: name })
      .eq('id', userId);
    const { error: circleError } =
      path === 'invite'
        ? await supabase.rpc('accept_invite', { p_code: code })
        : await supabase.rpc('create_senior', {
            p_first_name: path === 'me' ? name : seniorName.trim(),
            p_timezone: timeZone,
            p_role: path === 'me' ? 'senior' : 'family',
          });
    if (nameError || circleError) {
      setBusy(false);
      if (circleError?.code === 'PT404') {
        return setError(
          "That invite code didn't work. It may have been used already or be more than a week old. Ask for a new code.",
        );
      }
      return setError("That didn't save. Check your internet connection and try again.");
    }
    // The layout switches to the main screens once the circle loads.
    await refresh();
  }

  return (
    <Screen centered>
      <Label variant="title">Welcome to Alive &amp; Well</Label>
      <Label variant="muted">A couple of quick questions to get set up.</Label>

      <Field
        label="Your first name"
        value={myName}
        onChangeText={setMyName}
        autoCapitalize="words"
        autoComplete="given-name"
        returnKeyType="next"
      />

      <Choices
        label="Who will be checking in?"
        value={path}
        onChange={(p) => {
          setPath(p);
          setError('');
        }}
        options={[
          { value: 'me', label: 'Me' },
          { value: 'family', label: 'Someone in my family' },
          { value: 'invite', label: 'I have an invite code' },
        ]}
      />

      {path === 'family' ? (
        <Field
          label="Their first name"
          hint="They'll see it in greetings, like “Good morning, Margaret”."
          value={seniorName}
          onChangeText={setSeniorName}
          autoCapitalize="words"
        />
      ) : null}

      {path === 'invite' ? (
        <Field
          label="Invite code"
          hint="Someone in your family can make one under People."
          value={code}
          onChangeText={(v) => setCode(v.toUpperCase())}
          autoCapitalize="characters"
          autoCorrect={false}
          maxLength={10}
        />
      ) : (
        <Label variant="small">
          Check-in times will use {timeZoneName(timeZone)}. You can change this later under People.
        </Label>
      )}

      <Message text={error} />
      <Button title="Continue" onPress={onContinue} busy={busy} />
      <Button title="Sign out" kind="plain" onPress={() => supabase.auth.signOut()} disabled={busy} />
    </Screen>
  );
}

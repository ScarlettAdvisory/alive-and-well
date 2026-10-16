import { router } from 'expo-router';
import { useState } from 'react';

import { Button, Choices, Field, Label, Message, Screen } from '@/components/ui';
import { useCircle } from '@/lib/circle';
import { deviceTimeZone, timeZoneName } from '@/lib/format';
import { supabase } from '@/lib/supabase';

// Canada's zones, west to east.
const CANADA = [
  'America/Vancouver',
  'America/Edmonton',
  'America/Regina',
  'America/Winnipeg',
  'America/Toronto',
  'America/Halifax',
  'America/St_Johns',
];

export default function SeniorForm() {
  const { senior, refresh } = useCircle();
  const [name, setName] = useState(senior.first_name);
  const [timeZone, setTimeZone] = useState(senior.timezone);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const zones = [...CANADA];
  for (const z of [senior.timezone, deviceTimeZone()]) if (!zones.includes(z)) zones.push(z);

  async function save() {
    if (!name.trim()) return setError('Please enter their first name.');
    setBusy(true);
    setError('');
    const { error } = await supabase
      .from('seniors')
      .update({ first_name: name.trim(), timezone: timeZone })
      .eq('id', senior.id);
    if (error) {
      setBusy(false);
      return setError("That didn't save. Check your internet connection and try again.");
    }
    await refresh();
    router.back();
  }

  return (
    <Screen>
      <Label variant="title">Who checks in</Label>
      <Field label="First name" value={name} onChangeText={setName} autoCapitalize="words" maxLength={80} />
      <Choices
        label="Their time zone"
        value={timeZone}
        onChange={setTimeZone}
        options={zones.map((z) => ({
          value: z,
          label: timeZoneName(z) + (z === 'America/Regina' ? ' (Saskatchewan)' : ''),
        }))}
      />
      <Label variant="small">Check-in times happen in this time zone, wherever family are.</Label>
      <Message text={error} />
      <Button title="Save changes" onPress={save} busy={busy} />
      <Button title="Cancel" kind="plain" onPress={() => router.back()} disabled={busy} />
    </Screen>
  );
}

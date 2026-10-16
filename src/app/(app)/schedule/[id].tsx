import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';

import { Button, Choices, DeleteButton, Field, Label, Message, Screen, Toggle } from '@/components/ui';
import { useCircle } from '@/lib/circle';
import { DAY_NAMES } from '@/lib/format';
import { parseTimeOfDay, type Frequency } from '@/lib/schedule';
import { supabase } from '@/lib/supabase';

const HOURS = [12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const MINUTES = [0, 15, 30, 45];

export default function ScheduleForm() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { senior, schedules, refresh } = useCircle();
  const existing = schedules.find((s) => s.id === id);
  const start = parseTimeOfDay(existing?.time_of_day ?? '09:00');

  const [label, setLabel] = useState(existing?.label ?? '');
  const [hour12, setHour12] = useState(start.hour % 12 || 12);
  // Keep an existing off-the-quarter time (say 9:05) selectable rather than rounding it.
  const minuteOptions = MINUTES.includes(start.minute)
    ? MINUTES
    : [...MINUTES, start.minute].sort((a, b) => a - b);
  const [minute, setMinute] = useState(start.minute);
  const [pm, setPm] = useState<'am' | 'pm'>(start.hour >= 12 ? 'pm' : 'am');
  const [frequency, setFrequency] = useState<Frequency>(existing?.frequency ?? 'daily');
  const [day, setDay] = useState(existing?.day_of_week ?? 1);
  const [active, setActive] = useState(existing?.is_active ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  if (id !== 'new' && !existing) {
    return (
      <Screen centered>
        <Label>This check-in time has been removed.</Label>
        <Button title="Back" onPress={() => router.back()} />
      </Screen>
    );
  }

  async function save() {
    const hour24 = (hour12 % 12) + (pm === 'pm' ? 12 : 0);
    const row = {
      label: label.trim() || defaultLabel(hour24),
      time_of_day: `${String(hour24).padStart(2, '0')}:${String(minute).padStart(2, '0')}`,
      frequency,
      day_of_week: frequency === 'weekly' ? day : null,
      is_active: active,
    };
    setBusy(true);
    setError('');
    const { error } = existing
      ? await supabase.from('schedules').update(row).eq('id', existing.id)
      : await supabase.from('schedules').insert({ ...row, senior_id: senior.id });
    if (error) {
      setBusy(false);
      return setError("That didn't save. Check your internet connection and try again.");
    }
    await refresh();
    router.back();
  }

  async function remove() {
    if (!existing) return;
    const { error } = await supabase.from('schedules').delete().eq('id', existing.id);
    if (error) return setError("That didn't delete. Check your internet connection and try again.");
    await refresh();
    router.back();
  }

  return (
    <Screen>
      <Label variant="title">{existing ? 'Change check-in time' : 'Add a check-in time'}</Label>
      <Choices
        label="Hour"
        value={hour12}
        onChange={setHour12}
        options={HOURS.map((h) => ({ value: h, label: String(h) }))}
      />
      <Choices
        label="Minutes"
        value={minute}
        onChange={setMinute}
        options={minuteOptions.map((m) => ({ value: m, label: ':' + String(m).padStart(2, '0') }))}
      />
      <Choices
        label="Morning or afternoon"
        value={pm}
        onChange={setPm}
        options={[
          { value: 'am', label: 'a.m.' },
          { value: 'pm', label: 'p.m.' },
        ]}
      />
      <Choices
        label="How often"
        value={frequency}
        onChange={setFrequency}
        options={[
          { value: 'daily', label: 'Every day' },
          { value: 'weekdays', label: 'Weekdays' },
          { value: 'weekends', label: 'Weekends' },
          { value: 'weekly', label: 'Once a week' },
        ]}
      />
      {frequency === 'weekly' ? (
        <Choices
          label="Which day"
          value={day}
          onChange={setDay}
          options={[1, 2, 3, 4, 5, 6, 0].map((d) => ({ value: d, label: DAY_NAMES[d].slice(0, 3) }))}
        />
      ) : null}
      <Field
        label="Name (optional)"
        placeholder="For example: Morning check-in"
        value={label}
        onChangeText={setLabel}
        maxLength={80}
      />
      <Toggle label="Active (turn off to pause this check-in)" value={active} onChange={setActive} />
      <Message text={error} />
      <Button title={existing ? 'Save changes' : 'Add time'} onPress={save} busy={busy} />
      <Button title="Cancel" kind="plain" onPress={() => router.back()} disabled={busy} />
      {existing ? <DeleteButton title="Delete this check-in time" onConfirm={remove} /> : null}
    </Screen>
  );
}

function defaultLabel(hour24: number): string {
  if (hour24 < 12) return 'Morning check-in';
  if (hour24 < 17) return 'Afternoon check-in';
  return 'Evening check-in';
}

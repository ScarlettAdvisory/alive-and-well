import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';

import { Button, DeleteButton, Field, Label, Message, Screen, Toggle } from '@/components/ui';
import { useCircle } from '@/lib/circle';
import { formatPhone, normalizeEmail, normalizePhone } from '@/lib/sign-in-target';
import { supabase } from '@/lib/supabase';

export default function ContactForm() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { senior, contacts, refresh } = useCircle();
  const existing = contacts.find((x) => x.id === id);

  const [name, setName] = useState(existing?.name ?? '');
  const [relationship, setRelationship] = useState(existing?.relationship ?? '');
  const [email, setEmail] = useState(existing?.email ?? '');
  const [phone, setPhone] = useState(existing?.phone ? formatPhone(existing.phone) : '');
  const [notify, setNotify] = useState(existing?.notify_on_checkin ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  if (id !== 'new' && !existing) {
    return (
      <Screen centered>
        <Label>This person has been removed.</Label>
        <Button title="Back" onPress={() => router.back()} />
      </Screen>
    );
  }

  async function save() {
    setError('');
    const cleanEmail = email.trim() ? normalizeEmail(email) : null;
    const cleanPhone = phone.trim() ? normalizePhone(phone) : null;
    if (!name.trim()) return setError('Please enter their name.');
    if (!email.trim() && !phone.trim()) return setError('Add an email address, a mobile number, or both.');
    if (email.trim() && !cleanEmail) return setError("That email address doesn't look complete.");
    if (phone.trim() && !cleanPhone) return setError('Enter a 10-digit phone number, like 613-555-0123.');

    const row = {
      name: name.trim(),
      relationship: relationship.trim() || null,
      email: cleanEmail,
      phone: cleanPhone,
      notify_on_checkin: notify,
    };
    setBusy(true);
    const { error } = existing
      ? await supabase.from('contacts').update(row).eq('id', existing.id)
      : await supabase.from('contacts').insert({ ...row, senior_id: senior.id });
    if (error) {
      setBusy(false);
      return setError("That didn't save. Check your internet connection and try again.");
    }
    await refresh();
    router.back();
  }

  async function remove() {
    if (!existing) return;
    const { error } = await supabase.from('contacts').delete().eq('id', existing.id);
    if (error) return setError("That didn't delete. Check your internet connection and try again.");
    await refresh();
    router.back();
  }

  return (
    <Screen>
      <Label variant="title">{existing ? `Edit ${existing.name}` : 'Add a person'}</Label>
      <Field label="Name" value={name} onChangeText={setName} autoCapitalize="words" maxLength={80} />
      <Field
        label="Relationship (optional)"
        placeholder="Daughter, neighbour…"
        value={relationship}
        onChangeText={setRelationship}
        maxLength={80}
      />
      <Field
        label="Mobile number"
        value={phone}
        onChangeText={setPhone}
        inputMode="tel"
        autoComplete="tel"
      />
      <Field
        label="Email"
        value={email}
        onChangeText={setEmail}
        inputMode="email"
        autoCapitalize="none"
        autoCorrect={false}
        autoComplete="email"
      />
      <Toggle
        label={`Also tell them every time ${senior.first_name} says "I'm OK"`}
        value={notify}
        onChange={setNotify}
      />
      <Message text={error} />
      <Button title={existing ? 'Save changes' : 'Add person'} onPress={save} busy={busy} />
      <Button title="Cancel" kind="plain" onPress={() => router.back()} disabled={busy} />
      {existing ? <DeleteButton title={`Remove ${existing.name}`} onConfirm={remove} /> : null}
    </Screen>
  );
}

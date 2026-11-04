import { router } from 'expo-router';
import { useState } from 'react';

import { Button, Card, DeleteButton, Label, Message, Screen } from '@/components/ui';
import { useCircle } from '@/lib/circle';
import { supabase } from '@/lib/supabase';

// Deletes the signed-in person's account (an App Store requirement). The
// delete_account() database function decides what else goes with it.
export default function AccountScreen() {
  const { senior, people } = useCircle();
  const [error, setError] = useState('');
  const shared = people.some((p) => !p.is_me);

  async function deleteAccount() {
    setError('');
    const { error } = await supabase.rpc('delete_account');
    if (error) {
      return setError("Your account wasn't deleted. Check your internet connection and try again.");
    }
    // The sign-in no longer exists; clearing it here sends the app back to the sign-in screen.
    await supabase.auth.signOut({ scope: 'local' });
  }

  return (
    <Screen>
      <Label variant="title">Delete your account</Label>
      <Card tone="sunk">
        <Label>This permanently deletes your sign-in and your name.</Label>
        {shared ? (
          <Label>
            {senior.first_name}&apos;s check-ins, times and contacts stay, because other people in
            the circle still use them. You can sign up again later and be invited back.
          </Label>
        ) : (
          <Label>
            You are the only person in {senior.first_name}&apos;s circle, so all of{' '}
            {senior.first_name}&apos;s check-ins, check-in times and contacts are deleted too.
          </Label>
        )}
        <Label variant="small">This can&apos;t be undone.</Label>
      </Card>
      <Message text={error} />
      <DeleteButton title="Delete my account" onConfirm={deleteAccount} />
      <Button title="Cancel" kind="plain" onPress={() => router.back()} />
    </Screen>
  );
}

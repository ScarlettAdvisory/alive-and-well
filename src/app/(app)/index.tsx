import { useState } from 'react';

import { Button, Label, Screen } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';

// Placeholder home screen for Phase 1. The check-in screen and family view
// replace it in Phase 2.
export default function HomeScreen() {
  const { session } = useAuth();
  const [busy, setBusy] = useState(false);
  const who = session?.user.email || session?.user.phone || 'your account';

  async function signOut() {
    setBusy(true);
    await supabase.auth.signOut();
    setBusy(false);
  }

  return (
    <Screen>
      <Label variant="title">You&apos;re signed in</Label>
      <Label variant="muted">Signed in as {who}.</Label>
      <Label>Check-ins and family settings are coming next.</Label>
      <Button title="Sign out" kind="plain" onPress={signOut} busy={busy} />
    </Screen>
  );
}

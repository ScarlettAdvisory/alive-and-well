import { Stack } from 'expo-router';

import { Button, Label, Loading, Screen } from '@/components/ui';
import { CircleProvider, useCircleState } from '@/lib/circle';
import { supabase } from '@/lib/supabase';

export default function SignedInLayout() {
  return (
    <CircleProvider>
      <CircleGate />
    </CircleProvider>
  );
}

// First-time users set up (or join) a senior's circle; everyone else gets the tabs.
function CircleGate() {
  const { state, refresh } = useCircleState();

  if (state.status === 'loading') return <Loading />;

  if (state.status === 'error') {
    return (
      <Screen centered>
        <Label variant="title">Something went wrong</Label>
        <Label>{state.message} Check your internet connection and try again.</Label>
        <Button title="Try again" onPress={refresh} />
        <Button title="Sign out" kind="plain" onPress={() => supabase.auth.signOut()} />
      </Screen>
    );
  }

  const ready = state.status === 'ready';
  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={ready}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="contact/[id]" options={{ presentation: 'modal' }} />
        <Stack.Screen name="schedule/[id]" options={{ presentation: 'modal' }} />
        <Stack.Screen name="invite" options={{ presentation: 'modal' }} />
        <Stack.Screen name="senior" options={{ presentation: 'modal' }} />
      </Stack.Protected>
      <Stack.Protected guard={!ready}>
        <Stack.Screen name="welcome" />
      </Stack.Protected>
    </Stack>
  );
}

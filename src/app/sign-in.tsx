import type { AuthError } from '@supabase/supabase-js';
import { useState } from 'react';

import { Button, Field, Label, Screen } from '@/components/ui';
import {
  describeSignInTarget,
  parseSignInTarget,
  type SignInTarget,
} from '@/lib/sign-in-target';
import { supabase } from '@/lib/supabase';

// Sign-in is passwordless: we send a one-time code to an email address or a
// mobile number, and the person types it in. New people get an account the
// first time they sign in.
export default function SignInScreen() {
  const [input, setInput] = useState('');
  const [target, setTarget] = useState<SignInTarget | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  async function sendCode(to: SignInTarget) {
    setBusy(true);
    setError('');
    setNotice('');
    const { error } =
      to.kind === 'email'
        ? await supabase.auth.signInWithOtp({ email: to.email })
        : await supabase.auth.signInWithOtp({ phone: to.phone });
    setBusy(false);
    if (error) {
      setError(friendlyError(error, 'send'));
      return false;
    }
    return true;
  }

  async function onSend() {
    const parsed = parseSignInTarget(input);
    if (!parsed) {
      setError('Enter an email address, or a 10-digit mobile number.');
      return;
    }
    if (await sendCode(parsed)) {
      setTarget(parsed);
      setCode('');
    }
  }

  async function onResend() {
    if (target && (await sendCode(target))) setNotice('We sent a new code.');
  }

  async function onVerify() {
    if (!target) return;
    const token = code.replace(/\D/g, '');
    if (token.length < 6) {
      setError('Enter the code from your message.');
      return;
    }
    setBusy(true);
    setError('');
    setNotice('');
    const { error } =
      target.kind === 'email'
        ? await supabase.auth.verifyOtp({ email: target.email, token, type: 'email' })
        : await supabase.auth.verifyOtp({ phone: target.phone, token, type: 'sms' });
    setBusy(false);
    // On success the auth listener swaps this screen for the app.
    if (error) setError(friendlyError(error, 'verify'));
  }

  function startOver() {
    setTarget(null);
    setCode('');
    setError('');
    setNotice('');
  }

  if (!target) {
    return (
      <Screen centered>
        <Label variant="title">Alive &amp; Well</Label>
        <Label variant="muted">
          Sign in with your email address or mobile number. We&apos;ll send you a code, so
          there&apos;s no password to remember.
        </Label>
        <Field
          label="Email or mobile number"
          value={input}
          onChangeText={setInput}
          onSubmitEditing={onSend}
          autoCapitalize="none"
          autoCorrect={false}
          autoComplete="email"
          inputMode="email"
          returnKeyType="send"
        />
        {error ? <Label variant="error" accessibilityLiveRegion="polite">{error}</Label> : null}
        <Button title="Send me a code" onPress={onSend} busy={busy} />
      </Screen>
    );
  }

  const where = describeSignInTarget(target);
  return (
    <Screen centered>
      <Label variant="title">Enter your code</Label>
      <Label variant="muted">
        We sent a code to {where}. It can take a minute to arrive
        {target.kind === 'email' ? ', and may land in your spam folder' : ''}.
      </Label>
      <Field
        label="Code"
        value={code}
        onChangeText={setCode}
        onSubmitEditing={onVerify}
        inputMode="numeric"
        autoComplete="one-time-code"
        textContentType="oneTimeCode"
        maxLength={10}
        returnKeyType="done"
        autoFocus
      />
      {error ? <Label variant="error" accessibilityLiveRegion="polite">{error}</Label> : null}
      {notice ? <Label accessibilityLiveRegion="polite">{notice}</Label> : null}
      <Button title="Sign in" onPress={onVerify} busy={busy} />
      <Button title="Send a new code" kind="plain" onPress={onResend} disabled={busy} />
      <Button
        title={target.kind === 'email' ? 'Use a different email' : 'Use a different number'}
        kind="plain"
        onPress={startOver}
        disabled={busy}
      />
    </Screen>
  );
}

function friendlyError(error: AuthError, step: 'send' | 'verify'): string {
  if (error.status === 429) return 'Too many tries. Please wait a minute, then try again.';
  if (step === 'verify') {
    return "That code didn't work. Check it and try again, or send a new code.";
  }
  if (error.name === 'AuthRetryableFetchError') {
    return "We couldn't connect. Check your internet connection and try again.";
  }
  return "We couldn't send a code just now. Please try again in a moment.";
}

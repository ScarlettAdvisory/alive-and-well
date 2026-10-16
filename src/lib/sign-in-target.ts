// Turns what someone typed into an email address or an E.164 phone number.
// Phone numbers default to North America (+1). No imports, so it runs under
// plain Node for tests.

export type SignInTarget = { kind: 'email'; email: string } | { kind: 'phone'; phone: string };

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function normalizeEmail(input: string): string | null {
  const email = input.trim().toLowerCase();
  return EMAIL.test(email) ? email : null;
}

/** "613-555-0123" -> "+16135550123"; null if it isn't a usable number. */
export function normalizePhone(input: string): string | null {
  const value = input.trim();
  // Only digits, spaces and common phone punctuation are allowed.
  if (!/^\+?[\d\s().-]+$/.test(value)) return null;
  const digits = value.replace(/\D/g, '');
  if (value.startsWith('+')) {
    return digits.length >= 8 && digits.length <= 15 && digits[0] !== '0' ? '+' + digits : null;
  }
  if (digits.length === 10) return '+1' + digits;
  if (digits.length === 11 && digits.startsWith('1')) return '+' + digits;
  return null;
}

/** "+16135550123" -> "(613) 555-0123"; other countries are shown as stored. */
export function formatPhone(phone: string): string {
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(phone);
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : phone;
}

export function parseSignInTarget(input: string): SignInTarget | null {
  if (input.includes('@')) {
    const email = normalizeEmail(input);
    return email ? { kind: 'email', email } : null;
  }
  const phone = normalizePhone(input);
  return phone ? { kind: 'phone', phone } : null;
}

/** How to show the target back to the person, e.g. "(613) 555-0123". */
export function describeSignInTarget(target: SignInTarget): string {
  return target.kind === 'email' ? target.email : formatPhone(target.phone);
}

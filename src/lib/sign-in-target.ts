// Turns what someone typed into the sign-in box into an email address or an
// E.164 phone number. Phone numbers default to North America (+1).

export type SignInTarget = { kind: 'email'; email: string } | { kind: 'phone'; phone: string };

export function parseSignInTarget(input: string): SignInTarget | null {
  const value = input.trim();
  if (value.includes('@')) {
    const email = value.toLowerCase();
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? { kind: 'email', email } : null;
  }

  // Only digits, spaces and common phone punctuation are allowed.
  if (!/^\+?[\d\s().-]+$/.test(value)) return null;
  const digits = value.replace(/\D/g, '');
  if (value.startsWith('+')) {
    return digits.length >= 8 && digits.length <= 15 && digits[0] !== '0'
      ? { kind: 'phone', phone: '+' + digits }
      : null;
  }
  if (digits.length === 10) return { kind: 'phone', phone: '+1' + digits };
  if (digits.length === 11 && digits.startsWith('1')) return { kind: 'phone', phone: '+' + digits };
  return null;
}

/** How to show the target back to the person, e.g. "(613) 555-0123". */
export function describeSignInTarget(target: SignInTarget): string {
  if (target.kind === 'email') return target.email;
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(target.phone);
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : target.phone;
}

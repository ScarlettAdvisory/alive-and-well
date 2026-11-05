// What the app may say about alerts. The server decides whether alert emails
// and texts are on (alert_status() in supabase/migrations/..._alerts.sql), so
// the wording follows the real system without a new app build. No imports, so
// it runs under plain Node for tests.

export type AlertStatus = { email: boolean; sms: boolean };

/** Used until the server says otherwise, and whenever it can't be reached. */
export const ALERTS_OFF: AlertStatus = { email: false, sms: false };

export type AlertContact = {
  email: string | null;
  phone: string | null;
  notify_on_checkin: boolean;
  sms_consent_at: string | null;
};

export function alertsLive(a: AlertStatus): boolean {
  return a.email || a.sms;
}

/** Whether a missed check-in or help request reaches this contact. */
export function canAlert(c: AlertContact, a: AlertStatus): boolean {
  return (a.email && !!c.email) || (a.sms && !!c.phone && !!c.sms_consent_at);
}

/** Whether a routine "I'm OK" reaches this contact (by email only). */
export function getsRoutine(c: AlertContact, a: AlertStatus): boolean {
  return a.email && c.notify_on_checkin && !!c.email;
}

/** "a text or email", "an email" or "a text". */
export function alertWords(a: AlertStatus): string {
  if (a.email && a.sms) return 'a text or email';
  return a.sms ? 'a text' : 'an email';
}

/** Why a contact won't get alerts, or null if they will. */
export function alertGap(c: AlertContact, a: AlertStatus): string | null {
  if (!alertsLive(a) || canAlert(c, a)) return null;
  if (!a.sms) return 'Not alerted: texts aren’t on yet, so add an email';
  if (c.phone && !c.sms_consent_at) return 'Not alerted: they haven’t agreed to texts';
  return 'Not alerted: add an email or mobile number';
}

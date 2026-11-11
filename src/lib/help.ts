// What kind of help the senior can ask for after "I need help". Keep in step
// with help_label() in supabase/migrations/20261111000000_help_types.sql.
// No imports, so it runs under plain Node for tests.

export type HelpType = 'doctor' | 'supplies' | 'transport' | 'personal_care' | 'other';

export const HELP_TYPES: { type: HelpType; label: string }[] = [
  { type: 'doctor', label: 'I need a doctor' },
  { type: 'supplies', label: 'I need food or medicine' },
  { type: 'transport', label: 'I need transport' },
  { type: 'personal_care', label: 'I need personal care' },
  { type: 'other', label: 'Other' },
];

/** The words for a help type, or null for "Other" or no choice. */
export function helpLabel(type: string | null | undefined): string | null {
  if (!type || type === 'other') return null;
  return HELP_TYPES.find((h) => h.type === type)?.label ?? null;
}

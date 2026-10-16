import { useEffect, useRef, useState, type ReactNode } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
  type TextInputProps,
  type TextProps,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { FontSize, MaxContentWidth, MinTouch, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';

type ScreenProps = {
  children: ReactNode;
  /** Centre short content vertically (sign-in, welcome); tab screens start at the top. */
  centered?: boolean;
  onRefresh?: () => Promise<void>;
};

/** A scrollable column that stays clear of the keyboard and notches. */
export function Screen({ children, centered, onRefresh }: ScreenProps) {
  const c = useTheme();
  const [refreshing, setRefreshing] = useState(false);
  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: c.background }]} edges={['top', 'left', 'right']}>
      <KeyboardAvoidingView
        style={styles.fill}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView
          contentContainerStyle={[styles.scroll, centered && styles.centered]}
          keyboardShouldPersistTaps="handled"
          refreshControl={
            onRefresh ? (
              <RefreshControl
                refreshing={refreshing}
                onRefresh={async () => {
                  setRefreshing(true);
                  await onRefresh();
                  setRefreshing(false);
                }}
              />
            ) : undefined
          }>
          <View style={styles.column}>{children}</View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

type Variant = 'title' | 'heading' | 'body' | 'muted' | 'small' | 'error';

export function Label({ variant = 'body', style, ...props }: TextProps & { variant?: Variant }) {
  const c = useTheme();
  const look = {
    title: { color: c.text, fontSize: FontSize.title, fontWeight: '700' as const, lineHeight: 40 },
    heading: { color: c.text, fontSize: FontSize.large, fontWeight: '700' as const, lineHeight: 30 },
    body: { color: c.text, fontSize: FontSize.body, lineHeight: 28 },
    muted: { color: c.muted, fontSize: FontSize.body, lineHeight: 28 },
    small: { color: c.muted, fontSize: FontSize.small, lineHeight: 22 },
    error: { color: c.help, fontSize: FontSize.body, lineHeight: 28, fontWeight: '700' as const },
  }[variant];
  return (
    <Text
      accessibilityRole={variant === 'title' || variant === 'heading' ? 'header' : undefined}
      style={[look, style]}
      {...props}
    />
  );
}

/** An error or confirmation line that screen readers announce. */
export function Message({ text, kind = 'error' }: { text: string; kind?: 'error' | 'info' }) {
  if (!text) return null;
  return (
    <Label variant={kind === 'error' ? 'error' : 'body'} accessibilityLiveRegion="polite">
      {text}
    </Label>
  );
}

export function Field({ label, hint, ...props }: TextInputProps & { label: string; hint?: string }) {
  const c = useTheme();
  return (
    <View style={styles.field}>
      <Label style={styles.fieldLabel}>{label}</Label>
      {hint ? <Label variant="small">{hint}</Label> : null}
      <TextInput
        accessibilityLabel={label}
        placeholderTextColor={c.muted}
        style={[
          styles.input,
          props.multiline && styles.multiline,
          { backgroundColor: c.surface, borderColor: c.line, color: c.text },
        ]}
        {...props}
      />
    </View>
  );
}

type ButtonProps = {
  title: string;
  onPress: () => void;
  kind?: 'primary' | 'plain' | 'danger';
  busy?: boolean;
  disabled?: boolean;
};

export function Button({ title, onPress, kind = 'primary', busy, disabled }: ButtonProps) {
  const c = useTheme();
  const inactive = disabled || busy;
  const look = {
    primary: { box: { backgroundColor: c.accent }, text: c.accentText },
    danger: { box: { backgroundColor: c.help }, text: c.helpText },
    plain: { box: { borderColor: c.line, borderWidth: 2 }, text: c.text },
  }[kind];
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: inactive, busy }}
      disabled={inactive}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        look.box,
        { opacity: inactive ? 0.6 : pressed ? 0.85 : 1 },
      ]}>
      {busy ? (
        <ActivityIndicator color={look.text} />
      ) : (
        <Text style={[styles.buttonText, { color: look.text }]}>{title}</Text>
      )}
    </Pressable>
  );
}

/** A delete button that asks for a second tap, since alerts don't work on web. */
export function DeleteButton({ title, onConfirm }: { title: string; onConfirm: () => Promise<void> }) {
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  return (
    <Button
      title={armed ? 'Tap again to delete' : title}
      kind={armed ? 'danger' : 'plain'}
      busy={busy}
      onPress={async () => {
        if (!armed) {
          setArmed(true);
          timer.current = setTimeout(() => setArmed(false), 4000);
          return;
        }
        clearTimeout(timer.current);
        setBusy(true);
        await onConfirm();
        setBusy(false);
        setArmed(false);
      }}
    />
  );
}

export function Card({ children, tone }: { children: ReactNode; tone?: 'ok' | 'help' | 'late' | 'sunk' }) {
  const c = useTheme();
  const backgroundColor = {
    ok: c.okSoft,
    help: c.helpSoft,
    late: c.lateSoft,
    sunk: c.sunk,
    none: c.surface,
  }[tone ?? 'none'];
  return (
    <View
      style={[
        styles.card,
        { backgroundColor, borderColor: tone ? 'transparent' : c.line },
      ]}>
      {children}
    </View>
  );
}

export type PillTone = 'ok' | 'help' | 'late' | 'wait';

export function Pill({ text, tone }: { text: string; tone: PillTone }) {
  const c = useTheme();
  const look = {
    ok: { bg: c.okSoft, fg: c.ok },
    help: { bg: c.helpSoft, fg: c.help },
    late: { bg: c.lateSoft, fg: c.late },
    wait: { bg: c.sunk, fg: c.muted },
  }[tone];
  return (
    <View style={[styles.pill, { backgroundColor: look.bg }]}>
      <Text style={[styles.pillText, { color: look.fg }]}>{text}</Text>
    </View>
  );
}

/** One line of a list: a title, optional detail lines, and something on the right. */
export function Row({
  title,
  lines,
  right,
  onPress,
  hint,
}: {
  title: ReactNode;
  lines?: (string | null | undefined | false)[];
  right?: ReactNode;
  onPress?: () => void;
  hint?: string;
}) {
  const c = useTheme();
  const body = (
    <View style={[styles.row, { borderBottomColor: c.line }]}>
      <View style={styles.rowMain}>
        {typeof title === 'string' ? <Label style={styles.rowTitle}>{title}</Label> : title}
        {lines?.filter(Boolean).map((line, i) => (
          <Label key={i} variant="small">
            {line as string}
          </Label>
        ))}
      </View>
      {right}
    </View>
  );
  if (!onPress) return body;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityHint={hint}
      onPress={onPress}
      style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}>
      {body}
    </Pressable>
  );
}

/** Pick one option from a few, as big tappable chips. */
export function Choices<T extends string | number>({
  label,
  options,
  value,
  onChange,
}: {
  label?: string;
  options: { value: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  const c = useTheme();
  return (
    <View style={styles.field} accessibilityRole="radiogroup" accessibilityLabel={label}>
      {label ? <Label style={styles.fieldLabel}>{label}</Label> : null}
      <View style={styles.chips}>
        {options.map((o) => {
          const selected = o.value === value;
          return (
            <Pressable
              key={String(o.value)}
              accessibilityRole="radio"
              accessibilityState={{ selected, checked: selected }}
              onPress={() => onChange(o.value)}
              style={[
                styles.chip,
                selected
                  ? { backgroundColor: c.accent, borderColor: c.accent }
                  : { backgroundColor: c.surface, borderColor: c.line },
              ]}>
              <Text style={[styles.chipText, { color: selected ? c.accentText : c.text }]}>
                {o.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

export function Toggle({
  label,
  value,
  onChange,
}: {
  label: string;
  value: boolean;
  onChange: (value: boolean) => void;
}) {
  const c = useTheme();
  return (
    <Pressable
      accessibilityRole="switch"
      accessibilityState={{ checked: value }}
      onPress={() => onChange(!value)}
      style={styles.toggle}>
      <Label style={styles.toggleLabel}>{label}</Label>
      <Switch
        value={value}
        onValueChange={onChange}
        trackColor={{ true: c.ok, false: c.line }}
        accessibilityLabel={label}
      />
    </Pressable>
  );
}

export function Loading() {
  const c = useTheme();
  return (
    <View style={[styles.fill, styles.center, { backgroundColor: c.background }]}>
      <ActivityIndicator size="large" color={c.accent} />
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  center: { alignItems: 'center', justifyContent: 'center' },
  scroll: { flexGrow: 1, padding: Spacing.md, paddingBottom: Spacing.xl },
  centered: { justifyContent: 'center' },
  column: { width: '100%', maxWidth: MaxContentWidth, alignSelf: 'center', gap: Spacing.lg },
  field: { gap: Spacing.sm },
  fieldLabel: { fontWeight: '700' },
  input: {
    minHeight: MinTouch,
    borderWidth: 2,
    borderRadius: 12,
    paddingHorizontal: Spacing.md,
    fontSize: FontSize.large,
  },
  multiline: { minHeight: 96, paddingVertical: Spacing.sm, textAlignVertical: 'top', fontSize: FontSize.body },
  button: {
    minHeight: MinTouch,
    borderRadius: 14,
    paddingHorizontal: Spacing.lg,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonText: { fontSize: FontSize.body, fontWeight: '700', textAlign: 'center' },
  card: { borderRadius: 16, borderWidth: 1, padding: Spacing.md, gap: Spacing.md },
  pill: { borderRadius: 999, paddingHorizontal: 12, paddingVertical: 4, alignSelf: 'center' },
  pillText: { fontSize: FontSize.small, fontWeight: '700' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
    paddingVertical: Spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    minHeight: MinTouch,
  },
  rowMain: { flex: 1, gap: 2 },
  rowTitle: { fontWeight: '700' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: Spacing.sm },
  chip: {
    minHeight: 48,
    minWidth: 56,
    borderRadius: 12,
    borderWidth: 2,
    paddingHorizontal: Spacing.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  chipText: { fontSize: FontSize.body, fontWeight: '700' },
  toggle: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: Spacing.md,
    minHeight: MinTouch,
  },
  toggleLabel: { flex: 1 },
});

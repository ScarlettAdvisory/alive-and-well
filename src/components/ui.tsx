import type { ReactNode } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextInputProps,
  type TextProps,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { FontSize, MaxContentWidth, MinTouch, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';

/** A centred, scrollable column that stays clear of the keyboard and notches. */
export function Screen({ children }: { children: ReactNode }) {
  const c = useTheme();
  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: c.background }]}>
      <KeyboardAvoidingView
        style={styles.fill}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled">
          <View style={styles.column}>{children}</View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

type Variant = 'title' | 'body' | 'muted' | 'error';

export function Label({ variant = 'body', style, ...props }: TextProps & { variant?: Variant }) {
  const c = useTheme();
  const look = {
    title: { color: c.text, fontSize: FontSize.title, fontWeight: '700' as const, lineHeight: 40 },
    body: { color: c.text, fontSize: FontSize.body, lineHeight: 28 },
    muted: { color: c.muted, fontSize: FontSize.body, lineHeight: 28 },
    error: { color: c.help, fontSize: FontSize.body, lineHeight: 28, fontWeight: '700' as const },
  }[variant];
  return (
    <Text
      accessibilityRole={variant === 'title' ? 'header' : undefined}
      style={[look, style]}
      {...props}
    />
  );
}

export function Field({ label, ...props }: TextInputProps & { label: string }) {
  const c = useTheme();
  return (
    <View style={styles.field}>
      <Label style={styles.fieldLabel}>{label}</Label>
      <TextInput
        accessibilityLabel={label}
        placeholderTextColor={c.muted}
        style={[
          styles.input,
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
  kind?: 'primary' | 'plain';
  busy?: boolean;
  disabled?: boolean;
};

export function Button({ title, onPress, kind = 'primary', busy, disabled }: ButtonProps) {
  const c = useTheme();
  const primary = kind === 'primary';
  const inactive = disabled || busy;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: inactive, busy }}
      disabled={inactive}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        primary
          ? { backgroundColor: c.accent }
          : { backgroundColor: 'transparent', borderColor: c.line, borderWidth: 2 },
        { opacity: inactive ? 0.6 : pressed ? 0.85 : 1 },
      ]}>
      {busy ? (
        <ActivityIndicator color={primary ? c.accentText : c.text} />
      ) : (
        <Text style={[styles.buttonText, { color: primary ? c.accentText : c.text }]}>
          {title}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { flexGrow: 1, justifyContent: 'center', padding: Spacing.md },
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
  button: {
    minHeight: MinTouch,
    borderRadius: 14,
    paddingHorizontal: Spacing.lg,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonText: { fontSize: FontSize.body, fontWeight: '700' },
});

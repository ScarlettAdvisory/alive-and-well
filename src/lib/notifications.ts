// Check-in reminders on the senior's phone (expo-notifications, SDK 58).
//
// The server sends them (send_checkin_reminders() in
// supabase/migrations/..._reminders.sql) to every phone registered here by
// someone whose role is 'senior'. Tapping one opens the check-in screen.

import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { router } from 'expo-router';
import { useEffect } from 'react';
import { Platform } from 'react-native';

import { supabase } from '@/lib/supabase';

export type ReminderPermission = 'granted' | 'undetermined' | 'denied' | 'unsupported';

const native = Platform.OS === 'ios' || Platform.OS === 'android';
let registeredToken: string | null = null;

if (native) {
  // Show reminders even while the app is open.
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowBanner: true,
      shouldShowList: true,
      shouldPlaySound: true,
      shouldSetBadge: false,
    }),
  });
}

async function ensureChannel() {
  // Android 13+ only shows the permission prompt once a channel exists.
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('checkins', {
      name: 'Check-in reminders',
      importance: Notifications.AndroidImportance.HIGH,
      sound: 'default',
    });
  }
}

export async function reminderPermission(): Promise<ReminderPermission> {
  if (!native || !Device.isDevice) return 'unsupported';
  const p = await Notifications.getPermissionsAsync();
  if (p.status === 'granted') return 'granted';
  return p.status === 'denied' && !p.canAskAgain ? 'denied' : 'undetermined';
}

/** Shows the phone's "Allow notifications?" prompt. */
export async function askForReminders(): Promise<ReminderPermission> {
  if (!native || !Device.isDevice) return 'unsupported';
  await ensureChannel();
  const p = await Notifications.requestPermissionsAsync();
  return p.status === 'granted' ? 'granted' : 'denied';
}

/** Tells the server this phone should get reminders for this senior. */
export async function registerForReminders(seniorId: string): Promise<boolean> {
  if (!native || !Device.isDevice) return false;
  try {
    await ensureChannel();
    const projectId =
      Constants?.expoConfig?.extra?.eas?.projectId ?? Constants?.easConfig?.projectId;
    if (!projectId) return false;
    const token = (await Notifications.getExpoPushTokenAsync({ projectId })).data;
    const { error } = await supabase.rpc('register_push_device', {
      p_senior_id: seniorId,
      p_token: token,
      p_platform: Platform.OS,
    });
    if (error) return false;
    registeredToken = token;
    return true;
  } catch {
    // Offline or Expo unreachable: tried again next time the screen opens.
    return false;
  }
}

/** Stops reminders on this phone. Call before signing out. */
export async function forgetThisDevice() {
  if (!registeredToken) return;
  await supabase.rpc('forget_push_device', { p_token: registeredToken });
  registeredToken = null;
}

/**
 * Opens the check-in screen when a reminder is tapped, whether the app was
 * already running or was opened by the tap.
 */
export function useReminderTaps() {
  useEffect(() => {
    if (!native) return;
    function open(response: Notifications.NotificationResponse | null) {
      if (!response || response.actionIdentifier !== Notifications.DEFAULT_ACTION_IDENTIFIER) return;
      if (response.notification.request.content.data?.url !== '/') return;
      router.navigate({ pathname: '/', params: { reminder: String(Date.now()) } });
      Notifications.clearLastNotificationResponse();
    }
    open(Notifications.getLastNotificationResponse());
    const sub = Notifications.addNotificationResponseReceivedListener(open);
    return () => sub.remove();
  }, []);
}

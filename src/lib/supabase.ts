// Keeps the sign-in session in device storage (SQLite-backed localStorage on
// iOS/Android, the browser's own localStorage on web).
import 'expo-sqlite/localStorage/install';

import { createClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';

// The project URL is the bare https://<ref>.supabase.co; tolerate a pasted
// API path such as /rest/v1/ on the end.
const url = process.env.EXPO_PUBLIC_SUPABASE_URL?.trim().replace(/\/(rest|auth)\/v1\/?$/, '').replace(/\/+$/, '');
const key = process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim();

/** False until .env (or .env.local) has the project's URL and publishable key. */
export const isSupabaseConfigured = Boolean(url && key);

export const supabase = createClient(url || 'http://localhost:54321', key || 'not-configured', {
  auth: {
    storage: localStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});

// Refresh the session only while the app is in the foreground.
if (Platform.OS !== 'web') {
  AppState.addEventListener('change', (state) => {
    if (state === 'active') supabase.auth.startAutoRefresh();
    else supabase.auth.stopAutoRefresh();
  });
}

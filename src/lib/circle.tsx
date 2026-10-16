import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { AppState } from 'react-native';

import { useAuth } from '@/lib/auth';
import type { Checkin, Schedule } from '@/lib/schedule';
import { supabase } from '@/lib/supabase';

export type Role = 'senior' | 'family';

export type Senior = { id: string; first_name: string; timezone: string };

export type Contact = {
  id: string;
  name: string;
  relationship: string | null;
  email: string | null;
  phone: string | null;
  notify_on_checkin: boolean;
};

export type Person = { user_id: string; role: Role; display_name: string | null; is_me: boolean };

export type CircleData = {
  role: Role;
  senior: Senior;
  contacts: Contact[];
  schedules: Schedule[];
  checkins: Checkin[];
  people: Person[];
};

type CircleState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'none' }
  | ({ status: 'ready' } & CircleData);

type CircleContextValue = { state: CircleState; refresh: () => Promise<void> };

const CircleContext = createContext<CircleContextValue | null>(null);

const HISTORY_LIMIT = 60;
const POLL_MS = 60e3;

/**
 * Loads the senior this person looks after (or is), with their contacts,
 * schedules, recent check-ins and circle. One senior per account for now.
 * Refreshes every minute while the app is open, so family see new check-ins.
 */
export function CircleProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth();
  const userId = session?.user.id;
  const [state, setState] = useState<CircleState>({ status: 'loading' });
  // One load at a time; a refresh asked for mid-load runs again right after,
  // so a change the person just made is never missed.
  const inFlight = useRef<Promise<void> | null>(null);
  const again = useRef(false);

  const refresh = useCallback(async () => {
    if (!userId) return;
    if (inFlight.current) {
      again.current = true;
      return inFlight.current;
    }
    const run = async () => {
      do {
        again.current = false;
        try {
          setState(await loadCircle(userId));
        } catch {
          setState((prev) =>
            // Keep showing what we have if a background refresh fails.
            prev.status === 'ready'
              ? prev
              : { status: 'error', message: "We couldn't load your information." },
          );
        }
      } while (again.current);
    };
    inFlight.current = run().finally(() => {
      inFlight.current = null;
    });
    return inFlight.current;
  }, [userId]);

  useEffect(() => {
    refresh();
    const timer = setInterval(() => {
      if (AppState.currentState === 'active') refresh();
    }, POLL_MS);
    const sub = AppState.addEventListener('change', (s) => {
      if (s === 'active') refresh();
    });
    return () => {
      clearInterval(timer);
      sub.remove();
    };
  }, [refresh]);

  const value = useMemo(() => ({ state, refresh }), [state, refresh]);
  return <CircleContext.Provider value={value}>{children}</CircleContext.Provider>;
}

async function loadCircle(userId: string): Promise<CircleState> {
  const { data: membership, error } = await supabase
    .from('circle_members')
    .select('role, senior:seniors(id, first_name, timezone)')
    .eq('user_id', userId)
    .order('created_at')
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (!membership) return { status: 'none' };

  const senior = membership.senior as unknown as Senior;
  const [contacts, schedules, checkins, people] = await Promise.all([
    supabase
      .from('contacts')
      .select('id, name, relationship, email, phone, notify_on_checkin')
      .eq('senior_id', senior.id)
      .order('name'),
    supabase
      .from('schedules')
      .select('id, label, time_of_day, frequency, day_of_week, is_active')
      .eq('senior_id', senior.id)
      .order('time_of_day'),
    supabase
      .from('checkins')
      .select('id, status, occurred_at, schedule_id, scheduled_for, message')
      .eq('senior_id', senior.id)
      .order('occurred_at', { ascending: false })
      .limit(HISTORY_LIMIT),
    supabase.rpc('circle_people', { p_senior_id: senior.id }),
  ]);
  for (const r of [contacts, schedules, checkins, people]) if (r.error) throw r.error;

  return {
    status: 'ready',
    role: membership.role as Role,
    senior,
    contacts: (contacts.data ?? []) as Contact[],
    schedules: (schedules.data ?? []) as Schedule[],
    checkins: (checkins.data ?? []) as Checkin[],
    people: (people.data ?? []) as Person[],
  };
}

export function useCircleState(): CircleContextValue {
  const ctx = useContext(CircleContext);
  if (!ctx) throw new Error('useCircleState must be used inside CircleProvider');
  return ctx;
}

/** For screens that only render once the circle has loaded. */
export function useCircle(): CircleData & { refresh: () => Promise<void> } {
  const { state, refresh } = useCircleState();
  if (state.status !== 'ready') throw new Error('Circle is not loaded');
  return { ...state, refresh };
}

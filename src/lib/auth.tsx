import type { Session } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import { isSupabaseConfigured, supabase } from '@/lib/supabase';

type AuthState = { session: Session | null; loading: boolean };

const AuthContext = createContext<AuthState>({ session: null, loading: true });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({
    session: null,
    loading: isSupabaseConfigured,
  });

  useEffect(() => {
    if (!isSupabaseConfigured) return;
    supabase.auth
      .getSession()
      .then(({ data }) => setState({ session: data.session, loading: false }))
      .catch(() => setState({ session: null, loading: false }));
    const { data } = supabase.auth.onAuthStateChange((_event, session) =>
      setState({ session, loading: false }),
    );
    return () => data.subscription.unsubscribe();
  }, []);

  return <AuthContext.Provider value={state}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  return useContext(AuthContext);
}

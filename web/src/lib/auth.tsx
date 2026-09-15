import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase.ts';

interface AuthState {
  session: Session | null;
  loading: boolean;
  signOut: () => Promise<void>;
  signOutEverywhere: () => Promise<void>;
  resetPasswordForEmail: (email: string) => Promise<{ error: string | null }>;
}

const Ctx = createContext<AuthState>({
  session: null,
  loading: true,
  signOut: async () => {},
  signOutEverywhere: async () => {},
  resetPasswordForEmail: async () => ({ error: null }),
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  return (
    <Ctx.Provider
      value={{
        session,
        loading,
        signOut: () => supabase.auth.signOut().then(() => {}),
        // 'global' revokes every refresh token for this user, not just the
        // current tab's — every other signed-in device is signed out too.
        signOutEverywhere: () => supabase.auth.signOut({ scope: 'global' }).then(() => {}),
        resetPasswordForEmail: async (email) => {
          const { error } = await supabase.auth.resetPasswordForEmail(email);
          return { error: error?.message ?? null };
        },
      }}
    >
      {children}
    </Ctx.Provider>
  );
}

export const useAuth = () => useContext(Ctx);

# Alive & Well

A daily check-in app for seniors and their families. The senior taps "I'm OK" at their check-in times (or "I need help"), and family are alerted when a check-in is missed. See [PLAN.md](PLAN.md) for the full plan.

The app is built with Expo (React Native) for iPhone, Android and web, with Supabase for accounts and data.

## Status

- **Phase 1 (Foundations)** is done: the database tables and access rules, plus passwordless sign-in with a one-time code by email or text message.
- **Phase 2 (Check-in app)** is done: the senior's check-in screen ("I'm OK", "I need help", a note, today's times, call buttons), the family's Today view, history, contacts, check-in times, and invite codes so the senior and family can each use their own phone.

Text and email alerts come in Phase 3. Until then the app says plainly that help requests are only visible in the app (`ALERTS_LIVE` in `src/constants/features.ts`).

## Set up Supabase (one time, about 15 minutes)

1. **Create the project.** Sign up at [supabase.com](https://supabase.com), create a new project, and choose **Canada (Central)** as the region so data stays in Canada. Save the database password somewhere safe.
2. **Create the tables.** In the project, open **SQL Editor**. Paste the whole of each file in [`supabase/migrations/`](supabase/migrations/), oldest first, and click **Run** after each:
   - `20261015000000_initial_schema.sql` (Phase 1)
   - `20261016000000_invites.sql` (Phase 2: invite codes)

   Each file only needs to be run once. When a later phase adds a new file, run just that one.
3. **Make sign-in emails show a code.** Supabase's emails contain a link by default; this app needs the code instead. Go to **Authentication > Emails**. In both the **Magic Link** and **Confirm signup** templates, replace the body with something like:

   ```html
   <h2>Your Alive &amp; Well code</h2>
   <p>Enter this code in the app to sign in:</p>
   <p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p>
   <p>If you didn't ask for this, you can ignore this email.</p>
   ```

   Set the subject of both to "Your Alive & Well sign-in code".
4. **Copy the keys into the app.** Copy `.env.example` to `.env.local`. From **Project Settings > API Keys**, paste the project URL and the **publishable** key. Never put the secret key in the app.

Signing in by text message also needs Supabase connected to Twilio (**Authentication > Sign In / Providers > Phone**). That's set up in Phase 3; until then, sign in by email.

Supabase's built-in email sender only sends a few emails an hour. That's enough for testing; Phase 3 switches to Resend for real use.

## Run the app

Needs [Node.js](https://nodejs.org) 20 or newer.

```bash
npm install
npx expo start
```

Then scan the QR code with the Camera app (iPhone) or the Expo Go app (Android), or press `w` to open the web version.

## Checks

```bash
npm run typecheck   # TypeScript
npm run lint        # ESLint
npm test            # check-in timing, time zones, phone numbers
npm run test:db     # database access rules, against a throwaway local Postgres
```

`test:db` needs Postgres installed locally (on a Mac: `brew install postgresql@16`).

## Project layout

- `src/app/`: screens (Expo Router; each file is a screen)
- `src/components/`, `src/lib/`, `src/hooks/`, `src/constants/`: shared code
- `supabase/migrations/`: database tables and access rules
- `supabase/tests/`: database access-rule tests
- `prototype/`: the original Claude-hosted version, kept for reference

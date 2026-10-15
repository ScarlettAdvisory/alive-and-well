# Alive & Well

Senior check-in app: scheduled check-ins, a big "I'm OK" button, an "I need help" button, and alerts to family when a check-in is missed or help is requested. Launching under seniorsalive.ca.

@AGENTS.md

## Where things are

- `PLAN.md`: the full plan for the standalone app (features, stack, costs, build phases, store/privacy/safety rules). Read it before starting new work.
- `README.md`: Supabase setup steps and how to run the app.
- `prototype/index.html`: the original Claude-hosted version, exported from claude.ai. It's the reference for screens, wording and behaviour. It depends on the claude.ai artifact runtime (`claude.use("db")`, `claude.use("mcp")`, `claude.use("user")`), so it won't run standalone.
- `src/app/`: screens. `sign-in.tsx` is public; everything in `(app)/` needs a session (`Stack.Protected` in `src/app/_layout.tsx`).
- `src/lib/supabase.ts`: the Supabase client. `src/lib/auth.tsx`: session context (`useAuth`).
- `supabase/migrations/`: schema and RLS. `supabase/tests/rls_test.sql`: RLS tests run by `npm run test:db`.

## Stack

- Expo SDK 57 (not 58: its `@expo/cli` wasn't published when the project started), Expo Router, TypeScript. One codebase for iPhone, Android and web (`web.output: "single"`).
- Supabase (Canadian region) for auth (one-time codes by email or phone), database and the scheduled missed-check-in job.
- Twilio for SMS, Resend for email from alerts@seniorsalive.ca, Expo push notifications for reminders.

## Commands

- `npm run typecheck`, `npm run lint`, `npm run test:db`. Run all three before calling work done.
- Add packages with `npx expo install <pkg>`. If Expo's API is unreachable, look up the SDK-compatible version in `node_modules/expo/bundledNativeModules.json` and `npm install` that exact range.

## Data model (supabase/migrations)

- `seniors` (first_name, timezone) with `circle_members` (senior_id, user_id, role senior|family). Everyone in a senior's circle can see and manage everything about them; that's what RLS checks via `is_circle_member()`.
- Create a senior only through the `create_senior(first_name, timezone, role)` RPC, which also adds the caller to the circle.
- `contacts`: alert recipients, no account needed. Phones are E.164. Texts need `sms_consent_at`.
- `schedules`: `time_of_day` in the senior's timezone, frequency daily/weekdays/weekends/weekly, `day_of_week` 0=Sunday.
- `checkins`: the app may only insert `ok`/`need_help`; a trigger forces `occurred_at`, `created_by` and `alert_state='pending'`. Rows are never updated or deleted by the app. The alert job (service role) records `no_response` rows, at most one per schedule occurrence, and updates alert fields.

## Behaviour to keep from the prototype

- Check-in window: checking in up to 2 hours early counts; a check-in is overdue 1 hour after its time.
- Routine "I'm OK" emails go only to contacts with notify_on_checkin on; missed-check-in and help alerts go to everyone.
- The senior's screen always shows "In an emergency, call 911" and says this is not a medical alert service.
- Large text, high contrast and big tap targets. The primary user is a senior.

## Rules

- Never promise faster or more reliable alerts than the system delivers.
- Test the alert path end to end whenever alert code changes.
- Account deletion must be possible from inside the app (App Store requirement).

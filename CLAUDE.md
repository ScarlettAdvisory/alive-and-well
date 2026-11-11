# Alive & Well

Senior check-in app: scheduled check-ins, a big "I'm OK" button, an "I need help" button, and alerts to family when a check-in is missed or help is requested. Launching under seniorsalive.ca.

@AGENTS.md

## Where things are

- `PLAN.md`: the full plan for the standalone app (features, stack, costs, build phases, store/privacy/safety rules). Read it before starting new work.
- `README.md`: Supabase setup steps, how to run the app and how to ship to TestFlight (`eas.json`).
- `prototype/index.html`: the original Claude-hosted version, exported from claude.ai. It's the reference for screens, wording and behaviour. It depends on the claude.ai artifact runtime (`claude.use("db")`, `claude.use("mcp")`, `claude.use("user")`), so it won't run standalone.
- `src/app/`: screens. `sign-in.tsx` is public; everything in `(app)/` needs a session (`Stack.Protected` in `src/app/_layout.tsx`). Inside, `(app)/_layout.tsx` shows `welcome.tsx` until the user is in a circle, then `(tabs)/` (Check in/Today, People, Schedule, History) plus modal forms (`contact/[id]`, `schedule/[id]`, `invite`, `senior`).
- `src/lib/supabase.ts`: the Supabase client. `src/lib/auth.tsx`: session context (`useAuth`). `src/lib/circle.tsx`: loads the user's senior, contacts, schedules, check-ins and circle (`useCircle`), refreshing every minute and on focus; call `refresh()` after any write.
- `src/lib/schedule.ts`: check-in timing in the senior's time zone (ported from the prototype). `src/lib/format.ts`: display formatting. Both have no imports so `npm test` runs them under plain Node.
- `src/lib/alerts.ts`: what the app may say about alerts, from the server's `alert_status()` (loaded into `useCircle().alerts`). While alerts are off, all wording must say help requests and missed check-ins are only visible in the app. Only promise alerts to contacts `canAlert()` reaches.
- `supabase/migrations/`: schema, RLS and the alert job. `supabase/tests/`: `rls_test.sql` and `alerts_test.sql`, run by `npm run test:db` against stubs of pg_net and Vault (`supabase_stub.sql`).
- `src/lib/notifications.ts`: check-in reminders (expo-notifications). The senior's check-in screen asks permission (`ReminderSetup` in `(tabs)/index.tsx`) and registers the phone with `register_push_device()`; a tapped reminder opens `/?reminder=…`, which resets the screen to the two buttons. Sign-out calls `forgetThisDevice()`.
- `supabase/setup/turn_on_alerts.sql`: run once in the SQL Editor with the Bird API key to switch alerts on.

## Stack

- Expo SDK 58, Expo Router, TypeScript. Keep the SDK current: the App Store's Expo Go only opens the newest SDK. One codebase for iPhone, Android and web (`web.output: "single"`).
- Supabase (Canadian region) for auth (one-time codes by email or phone), database and the scheduled missed-check-in job.
- Bird (bird.com) for alert texts and for email from alerts@seniorsalive.ca (DNS at IONOS). Expo push notifications for check-in reminders.

## Commands

- `npm run typecheck`, `npm run lint`, `npm test`, `npm run test:db`. Run all four before calling work done.
- Add packages with `npx expo install <pkg>`. If Expo's API is unreachable, look up the SDK-compatible version in `node_modules/expo/bundledNativeModules.json` and `npm install` that exact range.

## Data model (supabase/migrations)

- `seniors` (first_name, timezone) with `circle_members` (senior_id, user_id, role senior|family). Everyone in a senior's circle can see and manage everything about them; that's what RLS checks via `is_circle_member()`.
- Create a senior only through the `create_senior(first_name, timezone, role)` RPC, which also adds the caller to the circle.
- `contacts`: alert recipients, no account needed. Phones are E.164. Texts need `sms_consent_at`.
- `schedules`: `time_of_day` in the senior's timezone, frequency daily/weekdays/weekends/weekly, `day_of_week` 0=Sunday.
- `circle_invites`: one-time 8-character codes (expire in 7 days) made with `create_invite(senior_id, role)` and redeemed with `accept_invite(code)`, which raises `PT404` (HTTP 404) for a bad code. `circle_people(senior_id)` lists names and roles in a circle.
- `profiles.display_name`: the user's first name, asked on the welcome screen.
- `delete_account()` RPC: deletes the caller's auth user (cascading profile and memberships) and any senior whose circle would be left empty. Reached from People > Delete my account (`(app)/account.tsx`).
- Alerts (`20261105000000_alerts.sql`): pg_cron runs `process_alerts()` every minute. It records `no_response` check-ins an hour after a time with no response from 2 hours before to 4 hours after, then sends pending alerts through Bird's API with pg_net (key in Vault as `bird_api_key`) and logs each message in `alert_deliveries`, filled in from `net._http_response` on the next run. `alert_settings` (one row, no RLS access) holds the sender address, texting number and `email_live`/`sms_live`; nothing before `live_since` is alerted. Times in messages use `alert_time()`, which ends in "a.m.", so don't add a period after it.
- Reminders (`20261109000000_reminders.sql`): `send_checkin_reminders()` runs first in `process_alerts()`, even while alerts are off. It sends an Expo push at each check-in time and a nudge 30 minutes later (each only within 10 minutes of its time, once, and only if the senior hasn't checked in since 2 hours before) to `push_devices` of members whose role is senior. Logged in `checkin_reminders`; Expo's `DeviceNotRegistered` answers delete the token. `alert_settings.reminders_live` switches them off.
- Help choices (`20261111000000_help_types.sql`): `checkins.help_type` (doctor, supplies, transport, personal_care, other; only on need_help), chosen on the senior's screen after "I need help". `help_label()` in SQL and `HELP_TYPES` in `src/lib/help.ts` must list the same choices and words; alerts name the choice ("Pat asked for help: I need transport").
- `checkins`: the app may only insert `ok`/`need_help`; a trigger forces `occurred_at`, `created_by` and `alert_state='pending'`. Rows are never updated or deleted by the app. The alert job (runs as postgres, exempt from that trigger like the service role) records `no_response` rows, at most one per schedule occurrence, and updates alert fields.

## Behaviour to keep from the prototype

- Check-in window: checking in up to 2 hours early counts; a check-in is overdue 1 hour after its time.
- Routine "I'm OK" emails go only to contacts with notify_on_checkin on; missed-check-in and help alerts go to everyone.
- The senior's screen always shows "In an emergency, call 911" and says this is not a medical alert service.
- Large text, high contrast and big tap targets. The primary user is a senior.

## Gotchas

- The React Compiler is on. It can evaluate property reads inside callbacks while memoising, so never write `maybeUndefined!.id` in a handler; guard with `if (!x) return` first.
- Times use `en-CA` formatting ("9:00 a.m."); wrap sentences that end with a time in `tidy()` to avoid "a.m..".
- No native date picker: times are picked with `Choices` chips so it works the same on iOS, Android and web.

## Rules

- Never promise faster or more reliable alerts than the system delivers.
- Test the alert path end to end whenever alert code changes.
- Account deletion must be possible from inside the app (App Store requirement).

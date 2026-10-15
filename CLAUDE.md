# Alive & Well

Senior check-in app: scheduled check-ins, a big "I'm OK" button, an "I need help" button, and alerts to family when a check-in is missed or help is requested. Launching under seniorsalive.ca.

## Where things are

- `PLAN.md`: the full plan for the standalone app (features, stack, costs, build phases, store/privacy/safety rules). Read it before starting new work.
- `prototype/index.html`: the current Claude-hosted version, exported from claude.ai. It's the reference for screens, wording and behaviour. It depends on the claude.ai artifact runtime (`claude.use("db")`, `claude.use("mcp")`, `claude.use("user")`), so it won't run standalone.

## Target stack

- React Native + Expo, TypeScript, one codebase for iPhone, Android and web.
- Supabase (Canadian region) for auth (one-time codes by email or phone), database and the scheduled missed-check-in job.
- Twilio for SMS, Resend for email from alerts@seniorsalive.ca, Expo push notifications for reminders.

## Behaviour to keep from the prototype

- Data model: `settings` (senior's first name), `contacts` (name, relationship, email, phone, notify_on_checkin), `schedules` (label, time HH:MM, frequency daily/weekdays/weekends/weekly, day, is_active), `checkins` (status ok/need_help/no_response, message, at, scheduled_time, schedule_id, alert_state, notified_contacts).
- Check-in window: checking in up to 2 hours early counts; a check-in is overdue 1 hour after its time.
- Routine "I'm OK" emails go only to contacts with notify_on_checkin on; missed-check-in and help alerts go to everyone.
- The senior's screen always shows "In an emergency, call 911" and says this is not a medical alert service.
- Large text, high contrast and big tap targets. The primary user is a senior.

## Rules

- Never promise faster or more reliable alerts than the system delivers.
- Test the alert path end to end whenever alert code changes.
- Account deletion must be possible from inside the app (App Store requirement).

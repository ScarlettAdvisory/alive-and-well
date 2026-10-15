# Alive & Well: Standalone App Plan

_2026-10-15 · James Scarlett_

## Summary

Build Alive & Well as a native iPhone and Android app with its own backend, launched under seniorsalive.ca. It keeps the same idea as today's version: scheduled check-ins, an "I'm OK" button, an "I need help" button, and alerts to family when a check-in is missed.

What changes from the Claude-hosted version:

- **Alerts within minutes, not up to an hour.** A server checks for missed check-ins every few minutes and sends help alerts the moment the button is pressed.
- **Text messages and push notifications.** Family can get texts; the senior gets a reminder on their phone when it's time to check in.
- **No Claude account needed.** Seniors and family sign up in the app with an email or phone number.
- **Many families, not one.** Each senior has their own circle of contacts, so the app can grow beyond your family.

## Features for version 1

Version 1 does the core job well for one senior and their family; everything else waits until real families have used it.

**In version 1**

- **Senior's screen:** large "I'm OK" and "I need help" buttons, an optional note, today's check-in times, and family phone numbers with tap-to-call.
- **Check-in reminders:** a push notification at each check-in time, and a second nudge 30 minutes later if there's no response.
- **Missed check-in alerts:** texts and emails to family when a check-in is overdue, sent within about 5 minutes of the grace period ending.
- **Help alerts:** texts and emails to everyone within seconds of the button being pressed.
- **Family view:** today's status at a glance, history, and settings for contacts and schedules. A family member can manage everything for the senior.
- **Sign-in:** email or phone with a one-time code, so no passwords to remember.
- **Web version** at seniorsalive.ca with the same features, for family members on a computer.

**Later**

- Automated phone call to family when help is requested
- Multiple seniors per family account (for example, both parents)
- Quiet hours, holidays and travel mode
- French language support
- Apple Watch and fall detection integrations
- Paid plans, if you decide to offer it to other families

## How it's built

One codebase builds the iPhone app, the Android app and the web version, all talking to a Supabase backend that does the alert work.

The apps are built with React Native and Expo, written once in TypeScript. The senior's check-ins and the family's settings go into the database. The missed check-in job and the help alert send texts, emails and reminders through Twilio (SMS), Resend (email) and Expo push notifications. seniorsalive.ca hosts the web version, the privacy policy and the alert email address.

## Services and monthly costs

Running version 1 for one family costs about US$28 a month, almost all of it the database.

| Service | Job in the app | Plan | Cost (USD) |
|---|---|---|---|
| [Supabase](https://supabase.com/pricing) | Accounts, database, alert checks every few minutes | Pro | $25/month |
| [Twilio](https://www.twilio.com/en-us/sms/pricing/ca) | Text messages to family | Pay as you go | $1.15/month for a Canadian number, plus about $0.015 per text with carrier fees |
| [Resend](https://resend.com/pricing) | Alert emails from alerts@seniorsalive.ca | Free | $0 up to 3,000 emails a month (100 a day) |
| [Expo](https://expo.dev/pricing) | Builds the iPhone and Android apps | Free | $0 for up to 15 builds per platform a month |
| [Expo push notifications](https://docs.expo.dev/push-notifications/faq/) | Check-in reminders on the senior's phone | Included | $0 |
| Web hosting | seniorsalive.ca web version | Free tier (approximate) | $0 |
| Apple Developer Program | App Store listing | Already have | $99/year |
| [Google Play Console](https://support.google.com/googleplay/android-developer/answer/6112435?hl=en) | Google Play listing | One-time | $25 once |

Why not Supabase's free plan: free projects pause after a week of inactivity, and a safety app can't risk its alert checks stopping. At 100 texts a month, texting adds about $1.50. Costs grow slowly with more families; the database plan covers 100,000 monthly users before extra charges.

## Build phases

Working a few hours a week, expect roughly 8 to 12 weeks from first code to both app stores. Each phase ends with something you can try.

1. **Foundations (weeks 1–2):** set up Supabase, the database tables (seniors, contacts, schedules, check-ins), and sign-in with one-time codes. Ends with an empty app you can sign in to on your own phone.
2. **Check-in app (weeks 3–4):** the senior's screen, the family view, and contact and schedule settings. Ends with check-ins saved and visible to family.
3. **Alerts (weeks 5–6):** the server job that finds missed check-ins every few minutes, instant help alerts, texts through Twilio, emails through Resend from seniorsalive.ca, and push reminders. Ends with a full test where a missed check-in texts your own phone.
4. **Family trial (weeks 7–8):** your parent and family use it daily alongside the current Claude version. Fix what confuses them, especially text size and button placement.
5. **Store launch (weeks 9–12):** privacy policy and support page on seniorsalive.ca, App Store screenshots and review, Google Play's closed test and review. Ends with the app listed in both stores.

Keep the current Claude-hosted version running until the new app has worked reliably for at least two weeks.

## App store, privacy and safety

**App Store (Apple)**

- Apple rejects apps that are a website in a wrapper. Native push reminders and tap-to-call give the app real native features.
- Apps with sign-in must let people delete their account from inside the app.
- You need a privacy policy and support page; host both on seniorsalive.ca.

**Google Play**

- New personal developer accounts must run a closed test with a group of testers before publishing, and verify an Android device. The family trial can double as this test.

**Privacy**

- The app stores health-adjacent personal information about seniors. Store data in Supabase's Canadian region and describe what you collect in plain language.
- Canada's private-sector privacy law (PIPEDA) applies if the app is offered to other families. Get advice before charging money or launching publicly.
- Ask each contact to confirm they agree to receive alert texts, and honour "STOP" replies.

**Safety wording**

- Say clearly in the app and store listing that Alive & Well is not a medical alert or emergency service, and show "call 911" on the senior's screen.
- Test alerts end to end every time the alert code changes, and have the server notify you if the alert job stops running.

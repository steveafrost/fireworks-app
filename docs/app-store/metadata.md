# App Store submission copy

Everything App Store Connect asks for, written to be pasted — or pushed with the API
(`POST /v1/appPriceSchedules` for the price, `appStoreVersionLocalizations` for the text,
`appScreenshots` for the images). Character limits are noted because ASC enforces them.

## App record

| Field | Value |
|---|---|
| Name | `Fireworks Credit` |
| Subtitle (30) | `Credit left, spending, alerts` |
| Bundle ID | `com.whitebox.fireworks.ios` |
| SKU | `fireworks-ios` |
| Primary language | English (U.S.) |
| Primary category | Developer Tools |
| Secondary category | Utilities |
| Price | **$0.99** (USD price point `0.99`) |
| Age rating | 4+ |
| Copyright | `© 2026 Steve Frost` |
| Support URL | `https://github.com/steveafrost/fireworks-app/issues` |
| Marketing URL | `https://github.com/steveafrost/fireworks-app` |
| Privacy policy URL | `https://steveafrost.github.io/fireworks-app/privacy.html` |

Only **iOS** is ticked on the record. The Mac app is distributed outside the App Store
(a notarized DMG from GitHub releases), so ticking macOS would make ASC demand a Mac
build it will never get.

## Promotional text (170)

```
Know what your Fireworks credit is doing: balance, today's spend, burn rate and days
left, on one screen.
```

## Description (4000)

```
Fireworks Credit shows what your Fireworks AI account is doing, on the phone.

Balance, spend today, burn rate, days of credit left, and the seven-day picture behind
it — read from your own Fireworks account with an API key you paste once. The key is
stored in the iOS Keychain and used for nothing else.

WHAT IT SHOWS
• Credit left, and what percentage of this cycle it is
• Today's spend and your recent daily average
• A pace forecast: roughly how many days of credit remain at the current rate
• Seven days of spend, day by day
• Which models the spending went to

WHY A CYCLE
The dial divides by the credit added since your last top-up, not by everything you have
ever paid in. A lifetime denominator can only fall: after a year of steady use it reads a
few percent, and the low-credit warning has already fired once and gone quiet. The cycle
refills when you top up, which is exactly when the numbers should mean something again.

ALERTS
Optional notifications when the balance crosses a threshold you set, or when the pace
suggests you will run out sooner than you expect. They fire once per crossing and re-arm
when you top up.

PRIVACY
No account, no sign-up, no analytics, no tracking, no third-party SDKs. The app talks to
Fireworks with your key and keeps the readings on your device. There is no server of this
app's own, and nothing is sent anywhere else.

REQUIREMENTS
A Fireworks account and an API key — free to create at app.fireworks.ai. Without a key
you can tap "See a demo" to look around first.

Also available for macOS as a menu-bar app, free and open source:
github.com/steveafrost/fireworks-app
```

## Keywords (100, comma-separated, no spaces)

```
fireworks ai,credit,balance,spend,budget,usage,cost,llm,tokens,api,developer,monitor
```

## App Review notes

```
No account or credentials are needed to review this app.

On the first screen, tap "See a demo" to see it fully populated with sample figures.
Those figures are labelled DEMO on screen and are not any account's data — the label is
there so nobody mistakes them for a real balance.

A real balance needs a Fireworks API key, which is free to create at
app.fireworks.ai/settings/users/api-keys. Paste it on the first screen and the balance
appears within a few seconds. The app has no server of its own: the key is stored in the
iOS Keychain and sent only to Fireworks, to read the account's own balance and invoices.

Note that a Fireworks account with no credit will show a $0.00 balance — that is a
correct reading, not a failed one.
```

## App privacy answers

**Data Not Collected.** The app has no analytics, no tracking and no server; the API key
is stored on the device in the Keychain and transmitted only to Fireworks, the user's own
service. `docs/privacy.html` states this publicly.

## Screenshots

In `build/store-screens/app-store/` (regenerate with the UI test):

| Slot | Files | Size |
|---|---|---|
| iPhone 6.9" (`APP_IPHONE_67`) | `iphone-6.9/01-overview.png`, `iphone-6.9/03-setup.png` | 1290 × 2796 |
| iPad 13" (`APP_IPAD_PRO_3GEN_129`) | `ipad-13/01-overview.png`, `ipad-13/03-setup.png` | 2048 × 2732 |

The iPad set is not optional: the target declares `TARGETED_DEVICE_FAMILY: "1,2"`, so ASC
requires iPad screenshots.

`02-settings.png` and `demo-labelled.png` are kept for documentation but are **not** for
the listing: the settings sheet says "No key found yet" (the harness has no key, only
sample figures), which reads as a broken app next to a balance.

## What is still a person's job

1. **Create the app record** — no API can do this; it is browser-only.
2. **App privacy answers** — as of March 2026 these cannot be set with the API either.
3. **Upload the build** — Xcode Organizer, or `xcrun altool --upload-app` with an API key.

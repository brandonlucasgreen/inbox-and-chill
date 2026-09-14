# App Store listing — copy to paste (drafted 2026-09-11)

Everything App Store Connect asks for, in the order its forms ask, ready to
paste. Companion to `docs/app-store-release.md`, which is the sequence; this
is the words. Character limits are Apple's; each field below is under its
limit (checked by `scripts/check-listing.sh`… no such script — counted by
hand, so re-count if you edit).

**Two rules from the guidelines shape every field.** The listing must not
mention, link or hint at the build outside the store (3.1.1, 2.3) — so the
source list here is the store build's eleven, not thirteen, and "open
source" is not said. And 3.1.1 wants the trial's terms stated up front, so
the description says the price and the length plainly.

## App Information

| Field | Value |
|---|---|
| Name (30) | `Inbox & Chill` |
| Subtitle (30) | `Every notification, one queue` |
| Primary category | Productivity |
| Secondary category | Developer Tools |
| Privacy Policy URL | `https://inboxandchill.app/privacy` |
| Content rights | Does not contain, show, or access third-party content — **check this is how you read it**: the app displays the user's own notifications from services they connect; it hosts no third-party content of its own |
| Age rating | Answer *None* to every content question → 4+ |

## Pricing and Availability

Free. Availability: all territories unless you want fewer.

## App Privacy

**Data Not Collected.** True for the store build: no analytics, no crash
telemetry (MetricKit delivers to the app on the user's Mac, and nothing is
sent unless the user emails a report), no account, purchases handled by
Apple. The privacy page says the same. Publish the answers.

## In-App Purchases (both Non-Consumable)

### The unlock

| Field | Value |
|---|---|
| Reference name | `Full unlock` |
| Product ID | `lol.bgreen.inboxandchill.unlock` |
| Price | US$14.99 or US$15.00 (pick the one App Store Connect offers; let Apple derive other storefronts) |
| Display name (en-US, 30) | `Unlock Inbox & Chill` |
| Description (en-US, 45) | `Keeps syncing after the trial, for good.` |
| Review screenshot | Settings › General with the Purchase section visible |
| Review notes | `One-time purchase that keeps syncing running after the 14-day trial. Bought from Settings › General or the bar at the top of the queue.` |

### The trial

| Field | Value |
|---|---|
| Reference name | `14-day Trial` |
| Product ID | `lol.bgreen.inboxandchill.trial` |
| Price | Free (Price Tier 0) |
| Display name (en-US, 30) | `14-day Trial` |
| Description (en-US, 45) | `Try everything free for 14 days. No charge.` |
| Review screenshot | The welcome window's first screen (Start Free Trial) |
| Review notes | `The free trial item guideline 3.1.1 describes: pressing Start Free Trial on the welcome window purchases it at no charge, and its purchase date is the trial clock. If the purchase cannot complete the trial still starts, from a local timestamp.` |

Leave both in *Ready to Submit* and attach them on the version page.

## Version 1.0 page

### Screenshots (1280×800, 1440×900, 2560×1600 or 2880×1800; 1–10)

Take them on the store build (`scripts/build-app-store.sh --launch`) with
real-looking data, light and dark if you have the patience. Suggested order:

1. The panel open under the menu bar with a mixed queue: a Linear mention, a
   GitHub review request, a Slack DM, a Sentry issue, a Reminders task due
   today, one fold (a Slack channel with 3 items).
2. A row expanded with `D` showing context (a Slack thread, or a Linear
   comment).
3. The main window (⌘0) with the source sidebar.
4. Settings › Sources with several sources connected.
5. The welcome window's first screen — it doubles as the trial's review
   screenshot and shows the terms.

### Promotional text (170) — optional, editable without a new build

`Free for 14 days, then one purchase. No subscription, no account, nothing leaves your Mac.`

### Description (4000)

```
Inbox & Chill sits in your menu bar and gathers everything waiting on you — Linear mentions, GitHub review requests, Slack pings, Sentry issues, the tasks due today — into one queue you can work through from the keyboard and empty.

It doesn't replace the apps you already use. It tells you what needs you across all of them, so you stop checking each one for a red dot.

SOURCES
Linear · GitHub · GitLab · Trello · Asana · Slack · Sentry · Todoist · Apple Reminders · ntfy · any JSON feed. Every source connects with a credential you create yourself and paste in; it's stored in your Keychain and used only to talk to that service from your Mac.

ACTIONS THAT SYNC BACK
Snooze a Linear item and it snoozes in Linear. Complete a Reminders, Todoist or Asana task and it's done at the source. Dismiss a GitHub or GitLab notification and it's read there too. Where a service can't be told, the item is simply cleared here.

KEYBOARD-FIRST
↑↓ move · ⏎ open · E dismiss · S snooze · C complete · D details · U read/unread · ⌘P pin · ⌘Z undo. Type to filter. Related rows fold together — the same Slack channel, the same repo, the same sender — and you can select any rows and name them into a topic.

A MENU BAR BADGE THAT MEANS SOMETHING
Show a total, a high-signal-only count, a dot, or nothing. Each source decides what counts as high signal, and any source can opt out of the badge.

NOT POWERED BY AI
Every item is exactly what the source reported. Nothing is summarised or filtered by a model on your behalf.

NOTHING LEAVES YOUR MAC
No account, no server, no analytics. Your queue, archive and settings live on your Mac; your credentials live in your Keychain. A 90-day archive keeps what you've dismissed, searchable.

FREE FOR 14 DAYS, THEN ONE PURCHASE
Start the trial when you're ready and use the whole app for 14 days. After that, syncing pauses until a one-time in-app purchase — no subscription, and your queue and settings stay exactly where they are.

Requires macOS 15 or later.
```

### Keywords (100, comma-separated, no spaces)

`notifications,inbox,triage,menu bar,linear,github,slack,sentry,todoist,reminders,gitlab,asana,queue`

### URLs

| Field | Value |
|---|---|
| Support URL | `https://inboxandchill.app/faq` |
| Marketing URL | `https://inboxandchill.app` |
| Copyright | `2026 Brandon Lucas Green` |

### What's New in This Version (4000)

`First release on the Mac App Store.`

### Build

Select the processed 1.0.0 (13) upload. Export compliance is answered by
`ITSAppUsesNonExemptEncryption = false` in the plist; if the form still
asks, the app uses only the standard HTTPS the OS provides, which is exempt.

### In-App Purchases and Subscriptions

Attach both products.

### App Review Information

| Field | Value |
|---|---|
| Sign-in required | **No** — there is no account. Leave the demo account fields empty. |
| Contact | your name, phone, `help@bgreen.lol` |
| Attachment | optional: a 30-second screen recording of first launch → Start Free Trial → add Reminders → the queue |

**Notes** (paste; fill the three credential blocks first):

```
Inbox & Chill is a menu bar app: it has no Dock icon and, after the welcome window, no window of its own until you ask. Look for the ✌️ icon in the menu bar, or press Option-Command-I to open the queue. Command-0 opens a full window with the same queue.

TRIAL AND PURCHASE
On first launch a welcome window states the trial terms and offers "Start Free Trial". Pressing it purchases the free "14-day Trial" item (guideline 3.1.1); nothing syncs until the trial is started. After 14 days syncing pauses and the app offers the one-time "Unlock Inbox & Chill" purchase; the queue, archive and settings remain readable meanwhile. Both the purchase and "Restore Purchase" are in Settings › General and in the bar at the top of the queue.

TRYING THE APP
The quickest source needs no credential: Settings › Sources › + › Apple Reminders. Grant Reminders access when macOS asks; any reminder due today or overdue appears in the queue within a minute.

Every other source needs an account at that service. Demo credentials for three of them:

Slack — user token: xoxp-… (workspace: … ; a channel with recent mentions: #…)
GitHub — classic personal access token with the notifications scope: ghp_…
Linear — API key: lin_api_…

Paste each in Settings › Sources › + › (the service) › the token field › Save. Items appear within about 30 seconds. These credentials are for review only and will be revoked after.

WHAT THE APP DOES NOT DO
There is no account, no server of ours and no analytics. Credentials are stored in the macOS Keychain and used only to call the service they belong to, from the Mac.
```

### Version Release

**Manually release this version.** Approval then puts nothing on sale until
you press Release — which is also when the website switches to the store
link (`inboxandchill.app` PR #2).

## After approval

1. App Store Connect › App Information shows the **Apple ID** of the record.
   Put it into the site's `APPLE_APP_ID` placeholders (two files, PR #2).
2. Release the version; merge PR #2.
3. Revoke the three demo credentials.

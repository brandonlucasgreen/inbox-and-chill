# Mac App Store release — runbook (2026-09-09)

Status: **the app side is built** (this PR): a free download, a 14-day trial
of everything, then one non-consumable in-app purchase to keep syncing. **The
paperwork side is Brandon's and none of it has been done yet** — no App ID,
no Apple Distribution certificate, no App Store Connect record, no product.
§2 is that list, in the order the dependencies force.

`docs/app-store-plan.md` is how the store *target* came to exist and what
the sandbox cost; this is how a build of it reaches customers. PLAN §2.1.12
holds the decision.

## 1. The business model, and why it is shaped this way

- **Free download, 14 days of full use, then syncing pauses until a
  one-time purchase.** Brandon's pick (2026-09-09): $15. Apple's USD price
  points include both $14.99 and $15.00 — pick in App Store Connect; the app
  never hard-codes a price, it shows StoreKit's `displayPrice`.
- **The trial is implicit — it starts on first launch, with no "start
  trial" step.** Guideline 3.1.1 describes a different mechanism: a $0
  non-consumable named "14-day Trial" the user "buys" to begin. That puts a
  purchase sheet and an Apple Account prompt in front of a menu bar app's
  first minute, which is the moment `FirstRun` exists to protect. Implicit
  trials anchored on the App Store's own download date are common and
  usually pass; **a strict reviewer may still ask for the $0 product**, and
  if one does the change is small: create the product, add a "Start Trial"
  button that purchases it, and stamp the clock from that transaction
  instead of from launch. The disclosure 3.1.1 *does* require before any
  trial — duration, what stops, what it costs — is on the welcome window
  and the in-queue welcome (`FirstRun.trialDisclosure`).
- **What "expired" means is unchanged from the direct build**: syncing
  pauses, loudly (`LicenseNotice` in the panel and main window, red); the
  queue, archive, triage and settings all keep working. Nothing is deleted.
- **The direct build is untouched.** `Licensing.isEnforced` is `true` only
  under `APP_STORE`; the direct build still has Lemon Squeezy wired and off.

## 2. Paperwork, in dependency order (Brandon, on the Mac)

Each step needs the one before it. Times are Apple's, not ours.

1. **Agreements, Tax, and Banking** — App Store Connect › Business. Sign the
   Paid Apps agreement, add a bank account and the tax forms. **Slowest step
   and gates everything below**: an in-app purchase cannot reach "Ready to
   Submit" until this is active, and Apple's approval can take days.
2. **App ID** — developer.apple.com › Certificates, Identifiers & Profiles ›
   Identifiers › + › App IDs › App. Explicit bundle id
   `lol.bgreen.inboxandchill` (the same id both builds use — a Mac has one
   or the other installed, `docs/app-store-plan.md` §2). In-App Purchase is
   on by default; App Sandbox needs nothing registered.
3. **Apple Distribution certificate + Mac App Store provisioning profile.**
   Easiest to let Xcode make both: in step 6's distribution assistant pick
   *Automatically manage signing*. This Mac currently holds only *Apple
   Development* and *Developer ID Application* identities (`security
   find-identity -v -p codesigning`, checked 2026-09-09), so expect Xcode to
   create the certificate the first time. Keep `project.yml` as it is —
   Developer ID for local builds; the store signature is applied at export.
4. **The app record** — App Store Connect › Apps › +. Platform macOS, name
   "Inbox & Chill" (availability not checked), primary language, the bundle
   id from step 2, an SKU (e.g. `inboxandchill-mac`). Then, on the record:
   - **Pricing**: Free. **Availability**: your call.
   - **Category**: Productivity — must match `LSApplicationCategoryType`
     in `project.yml`, which it does.
   - **Age rating** questionnaire.
   - **App Privacy**: *Data Not Collected* is the truthful answer — the app
     sends nothing to us; every token goes from the user's Mac to the
     service the user configured. The privacy policy has to say the same.
   - **Privacy Policy URL** and **Support URL** are mandatory. **Neither
     page exists yet** (the pre-release audit of 2026-09-04 found no `site/`
     and no privacy text anywhere in the repo). Two short pages on
     bgreen.lol; the copy PLAN §2.1.9/§2.1.11 settled applies.
5. **The in-app purchase** — the app record › Monetization › In-App
   Purchases › + › **Non-Consumable**.
   - Reference name: `Full unlock` (internal only).
   - **Product ID: `lol.bgreen.inboxandchill.unlock`, exactly.** It is
     `Licensing.appStoreProductID` in the binary and `productID` in
     `InboxAndChill.storekit`; a mismatch loads no product, the Buy button
     stays disabled, and Settings › General says which id it asked for.
   - Price: the $14.99 or $15.00 USD point; let Apple derive the others.
   - Localization (en-US): display name `Unlock Inbox & Chill`; description
     `Keeps syncing after the 14-day trial. One purchase, yours for good.`
   - **Review screenshot**: a picture of Settings › General with the
     Purchase section showing. Required before the product can be
     submitted; the reviewer sees it, customers do not.
   - Leave it in *Ready to Submit* and tick it on the version page (step 7,
     "In-App Purchases and Subscriptions") so it reviews with the app.
     A product cannot be approved on its own before the first app version.
6. **Archive and upload** — bump `MARKETING_VERSION` (the pending 1.0.0
   bump is the natural moment) and `CURRENT_PROJECT_VERSION` on `main`, then
   in Xcode: scheme **InboxAndChill-AppStore**, Product › Archive, Window ›
   Organizer › Distribute App › App Store Connect › Upload, *Automatically
   manage signing*, dSYM included (the store crash pipeline is MetricKit +
   Organizer, `docs/app-store-plan.md` §4). A locally signed store build
   carries `get-task-allow`; an archive does not — measured, §7 there.
7. **TestFlight** — the build appears under the record's TestFlight tab
   ~10–30 minutes after upload. Add yourself to an internal group and
   install through the TestFlight app on the Mac. **Purchases in TestFlight
   are sandbox purchases: free, and the trial ignores the sandbox's fixed
   2013 download date** (§3). This is the only way to exercise Buy and
   Restore against Apple's servers before customers do.
8. **The version page** — screenshots (macOS accepts 1280×800, 1440×900,
   2560×1600 or 2880×1800; the panel and the main window are the obvious
   two), description, keywords, the two URLs, the IAP ticked, export
   compliance already answered by `ITSAppUsesNonExemptEncryption` in the
   plist. **Say the trial out loud in the description**: "Free for 14 days.
   A one-time in-app purchase keeps syncing after that." **Do not mention
   or link the direct build** (3.1.1, 2.3). Then **App Review notes**:
   - It is a menu bar app: no Dock icon, no window at launch except the
     welcome. The ✌️ icon in the menu bar or ⌥⌘I opens the queue.
   - Apple Reminders is a zero-credential source the reviewer can add in
     under a minute; every other source needs the reviewer's own account
     with that service, so **offer demo credentials for at least Slack,
     GitHub and Linear** (a dedicated demo workspace/PAT/API key, revoked
     afterwards), or the app is an empty window.
   - Where the trial state, Buy and Restore live (Settings › General), that
     the trial starts on first launch with its terms on the welcome window,
     and that expiry pauses syncing only.
9. **Submit.** A rejection is answered on the same record; a resubmission
   bumps `CURRENT_PROJECT_VERSION`, which the direct build shares (a known
   cost, `docs/app-store-plan.md` §5).

## 3. How the app side works

`Sources/App/Licensing/` is now three things:

| Where | Compiled into | Job |
|---|---|---|
| `Licensing/*.swift` | both | `LicenseState`, trial math, `TrialNudge`, `LicenseNotice`, `AppState+License` — everything that does not care who takes the money |
| `Licensing/LemonSqueezy/` | direct only | `LicenseController` over a license key; `LicenseSection` |
| `Licensing/AppStore/` | store only | `LicenseController` over StoreKit 2; `PurchaseSection` |

Same class name in both provider folders, same surface (`state`, `problem`,
`priceLabel`, `onSyncPermissionChange`, `onStateEvaluated`), and each target
excludes the other folder in `project.yml` — so `AppState`, the notice bar
and the nudge compile once against whichever is present. The logic that
decides anything is in `Licensing` and tested from the direct target, because
the tests never run against the store target (CLAUDE.md rule 6).

- **The trial clock.** First launch stamps `license.trialStartedAt` in the
  Keychain (survives deleting the app). Then `AppTransaction.shared` is
  asked for the App Store's `originalPurchaseDate` — the day this Apple
  Account first downloaded the app, signed by Apple, surviving even a wiped
  Keychain. `Licensing.trialStart` takes the **earliest credible** of the
  two: never later, never a date in the future, and **never a
  non-production date**, because Apple documents the sandbox's original
  purchase date as a fixed 2013-08-01 (so TestFlight and Xcode runs trial
  from the local stamp). `AppTransaction.shared` throws rather than
  prompting when the app has no receipt; `refresh()` would prompt and is
  never called.
- **The purchase.** `Product.products(for:)` loads the one product;
  `product.purchase()` shows StoreKit's sheet; a verified transaction is
  finished and remembered as `license.appStoreUnlocked` in the Keychain.
  `Transaction.updates` runs for the app's lifetime so a refund (a
  transaction with `revocationDate`) locks again, and a purchase completed
  on another Mac shows up. **Restore Purchase** calls `AppStore.sync()` —
  the one call that shows an App Store sign-in sheet, so it is behind a
  button only. Ask to Buy's `.pending` is reported in orange, not red.
- **Offline never demotes**, same rule as the direct build: an empty
  entitlement list leaves a stored unlock alone and logs why. Only a
  revocation locks.
- **Every failure is a sentence in Settings › General** (rule 5): product
  not found (names the id), store unreachable, purchase unverified,
  restore found nothing, Keychain write failed. `LicenseNotice` carries
  Buy/Restore in the panel; if the price has not loaded its Buy button
  leads to Settings where the reason is.

### Testing it on this Mac

- **In Xcode, with the store scheme**: the scheme's run action names
  `InboxAndChill.storekit`, so the product loads locally, Buy shows Xcode's
  test sheet, and Debug › StoreKit › Manage Transactions can refund it to
  watch the app lock again. `INCHILL_LICENSE_STATE=expired|trialing:1|licensed`
  in the scheme's environment freezes a state for UI work (Debug only).
  The `.storekit` file was written by hand and **has not yet been opened in
  Xcode**; if Xcode rejects it, recreate it via File › New › StoreKit
  Configuration File with the same product id.
- **Outside Xcode** (`scripts/build-app-store.sh --launch`): there is no
  store to talk to. Measured 2026-09-09 on a fresh launch of the Release
  store build from `build/AppStore`, Developer ID signed, sandboxed:
  `trial started on this Mac` (the Keychain write succeeded under the
  sandbox) → `license state resolved: trialing(daysLeft: 14)` →
  `app transaction unavailable, trial stays on this Mac's stamp: unknown`
  (`StoreKitError.unknown`, 0.6 s after launch, no prompt) → `store product
  not found` 3 s later: **`Product.products(for:)` returns an empty list
  here rather than throwing**, so Settings shows the "has no product … for
  this app yet" line naming the id, not the unreachable one, and the Buy
  button in the notice bar leads to Settings. That wording is aimed at a
  customer whose App Store Connect product is missing; on a local build it
  is simply the expected state.
- **Resetting the trial on this Mac** (both builds share the Keychain
  service, but only the store build writes these):

  ```bash
  security delete-generic-password -s lol.bgreen.inboxandchill -a license.trialStartedAt
  security delete-generic-password -s lol.bgreen.inboxandchill -a license.appStoreUnlocked
  ```

  `scripts/reset-first-run.sh` wipes the whole service too.
- **The regression guards**: `scripts/verify-bundle.sh --app-store` now
  fails if the product id literal is missing from the store binary (the
  purchase path was not compiled in) or if `Enter License Key` is present
  (the direct build's button leaked past its `#if`). Both run in CI on every
  PR via `scripts/build-app-store.sh`.

## 4. Not verified, and how each would be

- **The purchase against Apple's servers.** Needs steps 1–7. Nothing here
  has met StoreKit's real sheet; the code follows the StoreKit 2 API
  contract and Apple's documentation, no more.
- **`AppTransaction.shared` on a store-installed build** returning the
  download date, and not prompting. Documentation says it throws when
  unavailable and that `refresh()` is the one that prompts; the first
  TestFlight install is the test — the log's `trial anchored to …` line
  says which clock won.
- **The `.storekit` file opening cleanly in Xcode** (hand-written JSON).
- **Review's reading of the implicit trial** (§1).
- **App name availability**, and whether Apple's USD price list offers
  $15.00 or only $14.99.

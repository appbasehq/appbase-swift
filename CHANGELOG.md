# Changelog: AppbaseAnalytics (Swift)

Newest first. Each release says what changed and what an upgrade needs. To upgrade, read every entry between your installed version and the target, apply each **Upgrade** step, then:

1. Set the package dependency to the exact version (Xcode: **Exact Version**; SwiftPM: `.package(url: "https://github.com/appbasehq/appbase-swift.git", exact: "VERSION")`) and commit `Package.resolved`.
2. Build, launch a development build, confirm events still arrive in App setup, and ship an app update. Installed apps keep their old SDK until then.

Wire schema v1, stored identities and queued events carry over between all versions below unless an entry says otherwise. React Native releases are in the [React Native changelog](https://appbase.so/docs/sdk-changelog.md); wire and storage details are in the [compatibility notes](https://appbase.so/docs/sdk-compatibility.md).

## Unreleased

Nothing yet.

## 0.8.0 (2026-10-14)

**Upgrade:** no code changes.

- Added `setProfile(email:name:)`: after `identify`, the dashboard shows this email and name for the account instead of its ID. It is stored apart from events, each call replaces the profile, and it is ignored (with a diagnostic) before `identify`. Optional; see [apps with accounts](https://appbase.so/docs/agent-setup.md#apps-with-accounts).
- When automatic build detection returns Unknown (for example a slow StoreKit answer during App Review), the SDK asks again in the background at about 5 s, 30 s, 2 min and 10 min. Later events carry the detected build.

## 0.7.0 (2026-10-13)

**Upgrade:** no code changes required. If the app uses RevenueCat, the integration is now recommended in place of hand-wired identity links and purchase callbacks; do not use both.

- Added `analytics.connectRevenueCat(...)`: links the RevenueCat customer to the analytics identity, reports access state for paywall views and records purchase attempts and outcomes. It uses only the existing public APIs and adds no RevenueCat dependency.

## 0.6.0 (2026-10-13)

**Upgrade:** no code changes. Apps that relied on `identify` refusing an account switch should still call `reset()` on logout.

- Text containing NUL is rejected at capture instead of failing on the server.
- `app_active` counts only returns from the background (Control Center, system alerts, Face ID and the purchase sheet no longer count as opens).
- `identify` with a different user while another is identified resets first, so the new person's activity is never credited to the previous account. `identity_linked` is sent only when the user changes.
- Requests send `X-Appbase-Sent-At` so the server can correct a wrong device clock.

## 0.5.0 (2026-10-12)

**Upgrade:** remove any build detection the app does itself (an explicit `runtimeEnvironment` overrides automatic detection). Use the app's single collection key in every build.

- On iOS, `Analytics.create` labels every event with the detected build from Apple's verified `AppTransaction` (App Store, TestFlight/App Review, development), bounded to two seconds and Unknown on failure. Set `automaticRuntimeEnvironment = false` to omit it.
- Plain HTTP is accepted only for loopback and private-network development hosts.
- Feedback carries the optional build environment.

## 0.4.0 (2026-10-12)

**Upgrade:** optional. Pass `runtimeEnvironment` to label events with their build, for example from `AppbaseRuntimeEnvironment.detect()`; superseded by automatic detection in 0.5.0.

- Added bounded native distribution detection (`AppbaseRuntimeEnvironment.detect()`) and the `runtimeEnvironment` option, recorded on each event without changing identity or storage.

## 0.3.0 (2026-10-08)

**Upgrade:** remove every `markNewUser()` call. New users now come from an event chosen in **App setup → New-user definition** (for example `account_created`).

- Removed `markNewUser()` and its local marker; acquisition uses a saved server-side event definition. Old stored state and queued marker events remain readable.

## 0.2.0 (2026-09-28)

- Added `markNewUser()` for explicit first-time use (removed again in 0.3.0).

## 0.1.0 (2026-09-25)

- First release for native Swift apps (Swift 6, iOS 15+, macOS 12+ for host tools): durable outbox with preserved event IDs and bounded retries, identity and consent, resumable onboarding and paywall workflows, RevenueCat identity links, explicit feedback and a bundled privacy manifest.

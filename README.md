# Appbase Analytics for Swift

Native iOS analytics with a durable offline outbox, onboarding, paywalls, RevenueCat identity evidence and explicit feedback. Swift 6, iOS 15+. macOS 12+ is supported for host testing and tools; automatic application lifecycle tracking is iOS-only. No third-party runtime dependencies.

## Install 0.1.0

In Xcode, choose **File → Add Package Dependencies**, enter `https://github.com/appbasehq/appbase-swift.git`, and select **Exact Version: 0.1.0**. Add the `AppbaseAnalytics` product to your app target.

For a Swift package, add this dependency and reference its library product from your target:

```swift
.package(url: "https://github.com/appbasehq/appbase-swift.git", exact: "0.1.0")
```

```swift
.product(name: "AppbaseAnalytics", package: "appbase-swift")
```

Commit the consuming app's `Package.resolved` and upgrade deliberately. SDK package versions are independent of the collection wire contract. [Source and release history](https://github.com/appbasehq/appbase-swift) are public; no third-party runtime package is required.

Physical-device behavior, the consuming app's merged App Store privacy report, and real Apple/RevenueCat sandbox purchases require validation in that app. Host tests, simulator checks and SDK publication do not establish those results.

## Setup

Add the `AppbaseAnalytics` library product to your app target. Create one instance for each app/environment and keep it for the app lifetime:

```swift
import Foundation
import AppbaseAnalytics

var options = AnalyticsOptions(
    apiURL: URL(string: "https://YOUR-COLLECTION-API")!,
    collectionKey: "YOUR_PUBLIC_COLLECTION_KEY",
    appVersion: "1.0.0"
)
options.onDiagnostic = { diagnostic in
    // Send diagnostic.code and a bounded message to your own development logger.
    // Avoid attaching keys, user identities or event payloads to diagnostics.
    print("Appbase: \(diagnostic.code.rawValue): \(diagnostic.message)")
}
let analytics = try await Analytics.create(options: options)
await analytics.track("workout_completed", properties: [
    "minutes": 15, "mode": "walking", "completed": true
])
```

New collection keys contain the app/environment namespace; legacy keys also require `options.appId` and `options.environment`. A production namespace requires HTTPS. Collection keys permit writes only; never place reporting, account, InsForge service or RevenueCat secret credentials in this SDK. Explicitly choose your environment instead of inferring production from a Release/TestFlight build.

Creation throws when configuration/storage is unusable. Do not silently delete corrupt state or manufacture a replacement identity; resolve the error with diagnostics and an explicit migration/recovery decision. File storage refuses competing owners of the same namespace. If you inject custom storage, you must ensure one live writer per namespace yourself.

## Delivery, errors and consent

`track` returns `true` after the event has been durably queued. It does not mean the server has received it. `false` means disabled/disposed collection, invalid data, a full queue or a storage failure; observe `onDiagnostic` and `getStatus()` for the reason. Workflow actions commit their state and event together, so failed saves do not advance onboarding/purchases.

Defaults are 1,000 queued events, batches of 50, a 15-second flush interval and a 10-second request timeout. Batch size clamps to 100. Configurable bounds are 10,000 queued events, 300-second timeout and one-day flush interval. A zero flush interval disables the timer. The default file store additionally caps the full saved state at 32 MiB and fails a larger save without replacing the previous state. Newest events are rejected when the queue is full; older events keep their original UUID, timestamp and identity. Flat property values accept strings, finite numbers, booleans, null and bounded string lists. Their 8 KiB budget follows the server’s compact ECMAScript JSON representation, including numeric exponent thresholds; string limits count UTF-16 units. Never include sensitive personal data in arbitrary properties.

```swift
await analytics.flush()             // Attempt delivery; still safe while offline.
let status = await analytics.getStatus()
if status.blocked {
    // Correct collection configuration first. Retry-After still applies.
    await analytics.resume()
}

await analytics.identify("opaque-internal-user-id")
// Before switching to another account:
await analytics.reset()
await analytics.identify("another-opaque-user-id")

let saved = await analytics.setEnabled(false)
// Handle saved == false: the user's opt-out could not be durably saved.
// Successful opt-out cancels current delivery and clears queued analytics/workflows.
await analytics.setEnabled(true)
```

`identify` refuses switching identified users without `reset`. Reset preserves older queued events with their original identity and changes the current anonymous identity. Identity changes must be awaited in account-transition order. Changing identity can succeed even if the separate `identity_linked` event hits a full queue; the diagnostic reports that dropped event. Opt-out persists across launch. Automatic iOS tracking emits `app_first_open` once per namespace and `app_active` at active initialization/foreground transitions. Do not duplicate these manually. Background entry attempts a bounded flush; durable storage, rather than the final network request, preserves events during termination.

There is one active delivery loop. Valid partial acknowledgements remove only their named events. Unknown, duplicated, contradictory, malformed or empty acknowledgements retain the batch. Network errors and 429/5xx retry with backoff and bounded Retry-After support; other HTTP failures block delivery until `resume`. Redirects are refused. Cancellation cannot retract a request that a server has already received.

Call `await analytics.dispose()` when deliberately replacing an instance; this stops lifecycle/timer work, cancels and awaits delivery, then releases its disk ownership. Existing queued state remains for the replacement. Subsequent mutations on a disposed client do nothing.

## Onboarding

```swift
let onboarding = try await analytics.onboarding(OnboardingOptions(
    id: "welcome", version: 1, steps: ["intro", "goal"],
    questions: [OnboardingQuestion(
        id: "goal", stepId: "goal", title: "Your goal?", type: .single,
        options: [OnboardingOption(id: "habit", label: "Build a habit")]
    )]
))
let attemptId = await onboarding.start() // Resumes after an app restart.
await onboarding.step("intro")
await onboarding.step("goal")
await onboarding.answer("goal", selection: "habit")
await onboarding.complete()
```

Omit `version` for the shared automatic fingerprint, or supply a positive safe integer/stable label. Treat a definition/version as immutable. Steps must be reached in order; revisiting reached steps is allowed. Answering requires reaching its step. Pass `selection: nil as [String]?` to record an explicit skip. Repeated identical answers are deduplicated; changed answers increment the revision. Use `restart()` only for a real new attempt. On reset/opt-out saved attempts are cleared; definition helpers remain reusable after collection resumes.

## Paywalls and RevenueCat

```swift
let wall = try await analytics.paywall(PaywallOptions(id: "premium", version: 1))
let view = await wall.view(
    placement: "after_onboarding", accessState: .inactive,
    productIds: ["premium.monthly"], onboarding: onboarding
)
let purchase = await view?.purchaseStarted(PaywallProduct(productId: "premium.monthly"))
// After the purchasing SDK callback, report its actual outcome and exact store transaction ID:
await purchase?.finished(PurchaseResult(result: .pending))
await view?.dismissed(reason: .closeButton)
await purchase?.finished(PurchaseResult(result: .succeeded, transactionId: "actual-store-transaction-id"))
```

Record `view` only when shown, not on each SwiftUI render. Omit access state/product lists when unknown. `wall.getView(savedViewId)` and `view.getPurchase(savedAttemptId)` resume saved handles after restart without duplicating events. Pending results can resolve after dismissal; final results cannot be replaced. Reset/opt-out invalidates saved handles. The last 100 presentations and at most 20 purchase attempts per presentation are resumable.

```swift
await analytics.linkRevenueCatUser(projectId: "your-revenuecat-project-id") {
    // Obtain the current app user ID from the consuming app's configured RevenueCat SDK.
    // Await the appropriate actor for your RevenueCat integration.
    return currentRevenueCatAppUserId
}
```

The helper is independent of the RevenueCat package. Call after its configuration/login and after analytics identity changes. A lookup that crosses an analytics account change is discarded. Identity evidence and client purchase callbacks never establish verified revenue; the existing server-side RevenueCat connection/webhooks verify billing. Never invent a transaction ID when none is available.

## Feedback

```swift
var retryId: String? = nil
// Keep retryId with the unchanged form payload when the user retries.
do {
    let receipt = try await analytics.feedback(FeedbackInput(
        message: "I could not finish onboarding", submissionId: retryId
    ))
    print("Received: \(receipt.id)")
} catch let error as FeedbackError {
    retryId = error.submissionId
    // Surface an appropriate error state; never show success without the receipt.
}
```

Feedback is explicit user contact independent of analytics consent. Disabled collection omits analytics identity. Feedback is not placed in the analytics outbox: the form owns its pending message/submission ID. Retry the same payload with the same ID after uncertain delivery. A valid matching server receipt is required for success. A reusable SwiftUI form is not included.

## Maintenance and verification

- `swift test --package-path sdks/swift` from the monorepo runs native tests and the exact shared JSON scenarios in `packages/contracts/mobile/scenarios`. Missing fixtures fail the conformance check.
- `xcodebuild -scheme AppbaseAnalytics -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` from this package verifies iOS compilation, including guarded lifecycle code.
- The canonical collection schemas, behavioral specification, limits, fingerprint vectors and compatibility policy are under `packages/contracts/mobile`. `MobileContract.swift` is generated; change canonical limits and run the repository generator instead of editing it.
- `AnalyticsStorage` and `AnalyticsTransport`, plus injected IDs/clock/diagnostics, support deterministic testing. Storage is synchronous on the SDK actor and must atomically save or throw. Custom transports must honor task cancellation and response bounds. No `await` occurs inside a mutation/persistence transaction; network results check generation before mutating current state.
- The SDK's file format is native-specific. Installing Swift alongside a React Native integration does not automatically migrate its AsyncStorage state.
- `PrivacyInfo.xcprivacy` is bundled with the library resource target. It describes the SDK's identifiers, product interactions, purchase callbacks and optional feedback. The app must review the merged privacy report and its own property collection before distribution. No advertising IDs or cross-app tracking are used by this SDK.

The SDK-only release contains the library, package manifest, README, privacy resource and license. Its standalone CI builds macOS and iOS simulator targets. Shared conformance fixtures, native behavioral tests, HTTP/PostgreSQL checks and lab applications remain in the private source monorepo and run there before release; their omission from this distribution is not a passing test result.

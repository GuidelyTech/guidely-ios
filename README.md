# Guidely iOS SDK

Native SwiftUI/UIKit SDK for [Guidely](https://guidelytech.com): product tours, tooltips, spotlights,
hotspots, banners, slideouts, checklists, in-app surveys and a resource center, authored in the
Guidely dashboard and rendered natively, plus feature flags & experiments. Targeting, frequency, queueing and analytics behave exactly
like the web SDK.

* iOS 15+, Swift 5.9+ (builds cleanly with Swift 6 toolchains)
* No third-party dependencies
* Renders in its own passthrough overlay window, so it never changes your view hierarchy

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/GuidelyTech/guidely-ios`,
and add the **Guidely** product to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/GuidelyTech/guidely-ios.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Guidely", package: "guidely-ios")]),
]
```

### CocoaPods

```ruby
pod 'GuidelyTech', '~> 0.1'
# or straight from the repository (works for every release, including those after CocoaPods trunk
# became read-only on 2 December 2026):
pod 'GuidelyTech', :git => 'https://github.com/GuidelyTech/guidely-ios.git', :tag => '0.2.0'
```

The pod's module is `Guidely` (`import Guidely`).

## Configure

Call `configure` once, as early as possible (App `init` or `application(_:didFinishLaunchingWithOptions:)`):

```swift
import Guidely

Guidely.configure(GuidelyOptions(
    projectId: "pk_dev_…",                                // environment public key (not a secret)
    apiURL: URL(string: "https://guidelytech.com")!,      // http://localhost:3000 for local dev
    environment: .development,                            // default: inferred from the key prefix
    debug: false,                                         // logs "[Guidely] …" to the console
    analytics: true,
    consent: .granted,                                    // .pending buffers, .denied drops events
    appVersion: nil,                                      // default: CFBundleShortVersionString
    theme: GuidelyTheme(primaryColor: "#4f46e5"),         // overrides the dashboard theme
    showChecklistLauncher: true,
    showResourceCenterLauncher: false,
    showMessengerLauncher: true,                          // Scout chat bubble (when Scout is on for iOS)
    launcherBottomOffset: 0,                              // extra inset above a custom tab bar
    onNavigate: { url in /* "/Deals" or "myapp://deals/42" from buttons, tasks and links */ },
    onError: { error in print(error) }
))
```

For local development against `http://localhost`, allow local networking in `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>
```

All SDK methods are `@MainActor` (call them from the main thread). The SDK never throws into your
app: errors go to `onError`, the `.error` listener event and the debug log.

## Identify users

```swift
let g = Guidely.shared
g.identify("user_1",
           traits: ["plan": "pro", "role": "admin", "signupDate": Date()],
           account: GuidelyAccount(id: "org_1", traits: ["name": "Acme", "seats": 25]))
g.updateTraits(["plan": "enterprise"])        // merges into the current user
g.setAccount(GuidelyAccount(id: "org_2"))
g.reset()                                      // on log out: new anonymous id, cleared state, new session
```

Traits accept JSON-compatible values: `String`, numbers, `Bool`, `Date` (sent as ISO 8601), arrays
and dictionaries. Keys that look sensitive (`password`, `token`, `card`, `ssn`, …) are dropped.

## Track events

```swift
g.track("deal_created", properties: ["value": 1200, "currency": "USD"])
```

Events drive `event` triggers, `advanceOn: event` steps and checklist tasks with `event` completion.

## Screens

Mobile apps have screens instead of URLs. Every URL-based feature (guide URL patterns, `url_match`
triggers, multi-screen steps, `url_visited` checklist tasks) matches the **screen path** `/<name>`.

```swift
// SwiftUI
DealsView().guidelyScreen("Deals")            // calls screen("Deals") on appear

// UIKit
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Guidely.shared.screen("Deals")
}
```

A URL pattern `/Deals` matches `screen("Deals")`; `/Deals/*` matches `screen("Deals/Detail")`.

## Targets

Tooltips, spotlights and hotspots anchor to views you tag with a **Guidely id**. Use the same id as
`data-guidely-id` on the web and the guide works on every platform.

```swift
// SwiftUI
Button("New deal") { … }
    .guidelyTarget("new-deal-button")

// UIKit
newDealButton.guidelyId = "new-deal-button"
```

In the dashboard, pick the target with a **Guidely id** selector (or `#id`,
`[data-guidely-id="…"]`, `[data-testid="…"]`). Taps on tagged views are observed without being
intercepted; they power `element_click` triggers, `advanceOn: element_click` and checklist `click`
tasks. A target counts as visible when it is attached to a window, not hidden, non-zero sized and
on screen; anchored cards follow it while it scrolls or rotates and hide while it is off screen.

> A SwiftUI `TabView`'s tab items cannot carry modifiers. Tag a custom tab bar's buttons, or tag the
> `UITabBar` item views from UIKit, to point guides at tabs.

## Guides, checklists and the resource center

```swift
g.startGuide("mobile-tour")            // by key or id; bypasses targeting and frequency
g.stopGuide()                          // silent stop
g.dismissGuide()                       // recorded as a dismissal
g.activeGuide                          // PublishedGuide?
g.guides                               // guides published to iOS
g.isGuideCompleted("mobile-tour")

g.checklistProgress("mobile-checklist")             // ChecklistProgress
g.completeChecklistTask("mobile-checklist", taskId: "notifications")
g.openChecklist("mobile-checklist")
g.closeChecklist("mobile-checklist")

g.openResourceCenter()                 // sheet with search, articles, FAQs and links
g.closeResourceCenter()
g.refresh()                            // re-fetch the published config
```

The checklist launcher floats above the bottom safe area (and above a visible `UITabBar`; set
`launcherBottomOffset` for a custom tab bar). Hide it with `showChecklistLauncher: false` and call
`openChecklist(_:)` from your own UI. The resource center has no floating launcher unless
`showResourceCenterLauncher: true`.

Help articles are grouped by collection; nested collections show as "Billing › Invoices", and
collections or articles targeted at audiences only list for identified users in one of them (this
is a listing filter, not access control). Article images render full width; videos and YouTube,
Vimeo, Loom or Wistia embeds show as a "▶ Watch on …" link that opens the video externally (no
inline players). PDFs read inline as a swipeable carousel of their pages; tapping a page opens a
full-screen reader with an "Open original" button. A PDF without rendered pages shows as a file card
that opens it.

## Scout messenger

Scout is Guidely's AI support messenger. It appears when the project switches the messenger on **and**
ticks **iOS** in Scout settings (the config then carries `messenger`); otherwise none of its UI exists
and the calls below do nothing.

* **Launcher**: a round chat bubble in the configured corner, stacked above the checklist launcher,
  with a red badge counting conversations that have unread replies. Hide it with
  `showMessengerLauncher: false` and open the messenger from your own UI.
* **Sheet**: *Home* (greeting, "Send us a message", your latest conversation, help search),
  *Messages* (your conversations, newest first) and *Help* (articles by collection with search,
  plus recommended guides, checklists, FAQs and links from the resource center). Scout replies stream
  in as they are written (`URLSession.bytes`); citation chips open the article, "Show me" buttons
  close the messenger and start the guide. "Talk to a person" hands the conversation to the team,
  and closed conversations ask for a rating.
* **Help routing**: while the messenger is on, `openResourceCenter()` opens its Help tab and the
  resource-center launcher option is ignored.

```swift
g.openMessenger()                 // or .home / .messages / .help
g.openMessenger(.help)
g.showNewMessage("I need help with invoices")   // new conversation, composer pre-filled
g.closeMessenger()
g.isMessengerEnabled

g.on(.messengerOpen) { _ in }
g.on(.conversationMessage) { event in
    if case .conversationMessage(let message, let conversation) = event { print(conversation.subject, message.body) }
}
```

Conversations are tied to this device by tokens stored in the SDK's storage
(`guidely:conversations:<key>`, newest 50); `reset()` forgets them and closes the messenger. While a
conversation is open the SDK polls for team replies every 5 s; otherwise it refreshes the unread
badge every 60 s. Polling stops in the background. Opening the sheet records `messenger_opened`.

## Feature flags

Feature flags and experiments come with the SDK you already configure: the flags of the key's
environment are downloaded (`GET /api/v1/sdk/flags`), cached for offline cold starts, refreshed every
60 s while the app is in the foreground and whenever it returns, and evaluated on the device by the
same rules as every other Guidely SDK (`docs/feature-flags-spec.md`, checked against
`sdks/conformance/flag-vectors.json`).

```swift
if Guidely.isFeatureEnabled("new-checkout") { … }
let color = Guidely.featureString("checkout-button-color", default: "blue")
let limit = Guidely.featureNumber("upload-limit-mb", default: 25)
let promo = Guidely.featureValue("promo", default: Promo.none)    // any Decodable
let details = Guidely.featureDetails("new-checkout")              // value, reason, ruleId, variationId, experiment
```

The getters can be called from any thread, never throw, and return `default` until flags load, for
unknown flags, and for null or wrong-type values. `isFeatureEnabled` (and `@FeatureFlag`,
`FeatureGate`) is the boolean getter: it returns the flag's value only when it is a JSON boolean, so a
string, number or JSON flag gives the default.

**SwiftUI** — views re-render when a value changes:

```swift
struct HomeView: View {
    @FeatureFlag("new-dashboard-banner") var showBanner
    @FeatureValue("checkout-button-color", default: "blue") var buttonColor: String

    var body: some View {
        FeatureGate("new-onboarding") {
            NewOnboarding()
        } else: {
            LegacyOnboarding()
        }
    }
}
```

`$showBanner` / `$buttonColor` give the full `FlagEvaluationResult`. `Guidely.flagsStore` is an
`ObservableObject` (`@ObservedObject var flags = Guidely.flagsStore`). In UIKit, listen for changes:

```swift
let subscription = Guidely.onFlagsChange { [weak self] in self?.applyFlags() }   // main thread; cancel() to stop
```

**Attributes.** Rules target these automatically: `id` (user id, or the anonymous id before
`identify`), `anonymousId`, every identify trait at the top level (a trait never replaces `id`),
`account` (`{ id, …account traits }`, so `account.plan` works), `$audiences` (audience ids),
`platform` (`ios`), `appVersion`, `osVersion`, `deviceType` (`phone` / `tablet`), `locale`,
`environment` and `screen` (the current `screen(_:)` name). Add or override attributes with:

```swift
Guidely.setFlagAttributes(["beta": true, "signedUpAt": user.createdAt])   // replaces the previous call's attributes
```

**Experiments.** When an experiment rule buckets a user, the SDK records an `experiment_viewed` event
(`experimentKey`, `variationId`, `variationName`, `flagKey`, `hashAttribute`) through the normal event
pipeline — once per experiment, variation and user per session, with the session attached, and
subject to consent like every other event. Assignments are sticky: a user keeps their variation when
the experiment's traffic changes (unless the experiment opts out or bumps its bucket version).

**Options** (`GuidelyOptions(flags: FlagsOptions(…))`, all optional):

| Option | Default | |
|---|---|---|
| `enabled` | `true` | `false` makes no flag requests; getters return defaults. |
| `pollInterval` | `60` | Seconds between refreshes in the foreground (`0` = only at start, on foreground and `refreshFlags()`). |
| `streaming` | `false` | Server-Sent Events (`/flags/stream`): refetch as soon as flags change; polling covers outages. |
| `remoteEval` | `false` | Evaluate on the server (`POST /flags/evaluate`); rules never reach the device. Required when the environment's exposure mode is *remote* (the SDK switches automatically when the server says so). Re-runs when attributes change. |
| `decryptionKey` | `nil` | Base64 key for environments with encrypted payloads (AES-256-GCM). |
| `overrides`, `overrideBehaviour` | `[:]`, `.localOverRemote` | Local values; `.localOnly` never fetches (serves overrides, then `bootstrapPayload`, never a payload cached by an earlier run), `.remoteOverLocal` only fills flags missing remotely. Also `Guidely.setFlagOverrides(_:behaviour:)`. |
| `devOverrides` | `true` | Read dev overrides from the launch environment (below); `false` ignores them. |
| `bootstrapPayload` | `nil` | A payload or remote-evaluation response (`Data`) used immediately, e.g. bundled with the app. |
| `reportUsage` | `true` | Aggregated evaluation counts to `/flags/events` (at most every 60 s, and when the app backgrounds; not while consent is pending/denied). |
| `stickyBucketing` | `true` | Persist experiment assignments. |
| `attributes` | `[:]` | Initial extra attributes. |
| `trackingCallback` | `nil` | `(FlagExperimentAssignment, FlagEvaluationResult) -> Void`, once per experiment/user/variation. |

`Guidely.refreshFlags()` refetches now; `Guidely.allFeatures()` evaluates every flag (QA screens; no
exposures are tracked).

**Without guides** (app extensions, widgets, flag-only apps) use the standalone client, which has the
same getters and options:

```swift
let flags = GuidelyFlagsClient(sdkKey: "pk_prod_…", attributes: ["id": userId])
flags.start()
await flags.ready()
if flags.isEnabled("new-widget") { … }
```

It is an `ObservableObject`, has `onChange`, `setAttributes`, `setOverrides`, `refresh()` and
`flushUsage()`, follows the app's foreground/background notifications, and sends exposures to
`/flags/events` itself. `FlagEvaluator.evaluate(payload, key:, attributes:)` is the pure evaluator.

### Dev overrides (UI tests / CI)

Both the embedded and the standalone client read flag values from the process environment once, at
start, so UI tests and CI can pin flags without changing the app (`docs/feature-flags-spec.md` §4.1):

| Variable | Holds |
|---|---|
| `GUIDELY_FLAG_OVERRIDES` | `{"new-checkout":true,"limit":5}`, or `new-checkout:true,limit:5,theme:"dark"` (values are JSON when they parse, text otherwise) |
| `GUIDELY_FLAG_OVERRIDES_FILE` | Path of a UTF-8 file holding the same text |
| `GUIDELY_FLAG_OVERRIDE_BEHAVIOUR` | `localOnly` (hermetic: no flag requests, no cached payload), `localOverRemote` or `remoteOverLocal` |

An overrides file holds a JSON object (or one `key:value` per line). Give each value the flag's
type; `null` or a value of the wrong type makes the getter return the fallback passed in code:

```json
{ "new-checkout": true, "checkout-button-color": "green", "max-cart-items": 25 }
```

```swift
// XCUITest
let app = XCUIApplication()
app.launchEnvironment["GUIDELY_FLAG_OVERRIDES"] = #"{"new-checkout":true,"checkout-button-color":"#16a34a"}"#
app.launchEnvironment["GUIDELY_FLAG_OVERRIDE_BEHAVIOUR"] = "localOnly"
app.launch()
```

```sh
# Simulator from a script: simctl passes SIMCTL_CHILD_* variables without the prefix
SIMCTL_CHILD_GUIDELY_FLAG_OVERRIDES='new-checkout:true,limit:5' xcrun simctl launch booted com.example.app
```

Per flag, the environment variable wins over the file, which wins over `overrides` /
`setFlagOverrides` (which replace only their own values; dev overrides stay). The behaviour variable
replaces `overrideBehaviour` until code passes an explicit `behaviour:`. When any variable supplies
something, the SDK logs one `[Guidely]` warning (even without `debug`) naming the sources, so one
left set is visible; malformed text, an unreadable file or an unknown behaviour is reported through
`onError` and ignored. `FlagsOptions(devOverrides: false)` turns all of this off.
`FlagOverridesText.parse(_:)` is the parser.

## Listeners

```swift
let token = g.on(.guideComplete) { event in
    if let guide = event.guide { print("completed", guide.key) }
}
g.off(token)
```

| Event | Payload (`GuidelyEvent`) |
|---|---|
| `.ready` / `.config` | `.ready(SdkConfig)` / `.config(SdkConfig)` |
| `.guideStart`, `.guideComplete`, `.guideDismiss`, `.guideSkip` | `PublishedGuide` |
| `.guideStep` | guide, `stepId`, `stepIndex` |
| `.checklistTask` | guide, `task`, `progress` |
| `.checklistComplete` | guide |
| `.surveySubmit` | guide, `answers`, `responseId` |
| `.resourceCenterOpen` | — |
| `.messengerOpen` | — |
| `.conversationMessage` | `MessengerMessage`, `conversation` (every Scout or team reply) |
| `.track` | `SdkEvent` (every analytics event) |
| `.identify` | `userId`, `anonymousId` |
| `.error` | `GuidelyError` |

Listeners survive repeated `configure` calls.

## Consent

```swift
Guidely.configure(GuidelyOptions(projectId: "pk_…", consent: .pending))  // buffer until the user decides
Guidely.shared.setConsent(.granted)    // sends buffered events
Guidely.shared.setConsent(.denied)     // drops queued events, stops sending
```

Analytics are also off when `analytics: false` or the project disables analytics. Guides still render.

## Session replay

Records sessions as masked screenshots plus touches and plays them back in the dashboard's
session-replay player, next to the session's analytics events. Recording is **opt-in in the app**:
screenshots of a native app are more sensitive than a masked web page, so ticking the project
setting alone never starts recording an existing app.

```swift
Guidely.configure(GuidelyOptions(
    projectId: "pk_live_…",
    sessionReplay: SessionReplayOptions(
        enabled: true,        // default false
        maskAllText: false,   // mask all text, not only text fields (also forced by the project setting)
        maskAllImages: false, // mask UIImageView / SwiftUI images
        captureInterval: 1    // seconds between screenshots (minimum 0.5)
    )
))
```

A session is recorded when the option is on, session replay is enabled in the project settings,
analytics are allowed (`analytics: true`, consent `.granted`, project analytics on) and the session
is sampled (the project's sample rate, decided once per session). Recording pauses in the
background (what was recorded is uploaded inside a background task) and resumes on return. A new
session (after the session timeout in the background, or `reset()`) starts a new recording.
`setConsent(.denied / .pending)` stops recording and **discards** whatever is buffered.

```swift
Guidely.shared.startSessionRecording() // record this session even if it was not sampled
Guidely.shared.stopSessionRecording()  // stop for the rest of the session (uploads what was recorded)
Guidely.shared.isRecording             // true while recording
Guidely.shared.sessionId               // the analytics session id (also the recording id)
```

### Masking

Masked areas are painted over with opaque grey rectangles **on the device, before the frame is
encoded**. The unmasked pixels are never sent.

* Always: `UITextField` (SwiftUI `TextField`, `SecureField`, search fields) and editable `UITextView`
  (`TextEditor`). The keyboard is never captured.
* `maskAllText`: also every `UILabel`, `UITextView` and SwiftUI `Text`.
* `maskAllImages`: every `UIImageView` and SwiftUI `Image`.
* Explicitly: `.guidelyMask()` on a SwiftUI view, `view.guidelyMask = true` on a `UIView`. Masking a
  container masks everything inside it.
* The project's replay block selectors: `#id` / `[data-guidely-id="id"]` selectors mask the targets
  registered with that Guidely id (`.guidelyTarget(id)` / `view.guidelyId`).

SwiftUI draws text and images in private views and layers rather than `UILabel` / `UIImageView`;
the SDK recognises them by class name (verified on iOS 27, where text is drawn in `CGDrawingLayer`s).
A future iOS release could change those internals, so mark views that must never be recorded with
`.guidelyMask()` rather than relying on `maskAllText` alone. Web views, maps and video are captured
as pixels like everything else: mask them explicitly if they can show sensitive data.

### How it works and limitations

* Every `captureInterval` the SDK draws the scene's visible windows (`drawHierarchy`, Guidely's own
  overlay included, keyboard windows excluded) at 1 pixel per point, paints the masks and encodes a
  JPEG (quality 0.6) off the main thread. Identical frames are skipped; typical frames are 20–80 KB.
* Cadence: no screenshot while a finger is down (drags and scrolls stay smooth), one 0.2 s after
  every touch ends, and after 3 unchanged screenshots in a row the interval stretches to
  `min(4 × captureInterval, 5 s)` until the screen changes or there is a touch, `screen()` or
  Guidely event.
* Drawing a frame runs on the main thread (UIKit requires it): about 40 ms in a Debug build on the
  iOS 27 simulator, not yet measured on devices. Raise `captureInterval` if your app is sensitive to
  that.
* Mask rectangles cover a view's laid-out frame and, while it animates, its on-screen
  (presentation) frame too, so views moving during a transition stay covered.
* The status bar is not part of the app's windows and is not recorded.
* Uploads: gzip JSON chunks every 10 s (or 1 MB, and when the app goes to the background), one at a
  time with retries; at most ~5 MB is kept in memory while offline and nothing is written to disk.

## Theming

Cards use the dashboard's project theme (primary, background and text colours, corner radius, font),
overridden per guide by its appearance settings and by `GuidelyOptions.theme`. A guide whose
appearance is `auto` follows the system light/dark mode; `dark` uses the dark palette. Fonts from the
theme's `fontFamily` list are used when installed in the app, otherwise the system font, always scaled
with Dynamic Type. Cards are announced to VoiceOver, every control is labelled, and only fades are
used when Reduce Motion is on.

## Deep links and navigation

Button actions, checklist tasks, resource-center links and links inside guide content follow these
rules: `http(s)` URLs open externally; relative paths (`/Deals`) and custom schemes
(`myapp://deals/42`) go to `onNavigate`. Without a handler, custom schemes are opened with
`UIApplication.open` and relative paths report an error.

```swift
onNavigate: { url in
    switch url.path {
    case "/Deals": router.tab = .deals
    default: router.open(url)
    }
}
```

## Lifecycle, sessions and offline behaviour

* The published config is cached with its ETag and used when offline; it is refreshed every
  `configRefreshInterval` (5 minutes) and when the app returns to the foreground with a stale config.
* A new session starts at launch and when the app returns after `sessionTimeoutMinutes` (dashboard
  setting, default 30) in the background.
* Analytics events are persisted (up to 200), sent in batches of 50 every 2 seconds, retried with
  backoff, and flushed when the app moves to the background.
* State (anonymous id, guide history, checklist progress, queue) is stored in the `UserDefaults`
  suite `tech.guidely.sdk` (`storage: .memory` keeps nothing).

## Troubleshooting

Turn on `debug: true` and filter the Xcode console (or Console.app) for `[Guidely]`. You will see the
config being loaded, which guides each evaluation selects, why guides are queued, every rendered
step and every request.

**A guide is not showing**

1. Is it published to the environment of your key (`pk_dev_…` = development) and does its
   **Platforms** setting include iOS? Guides published before mobile support are web-only. The log
   line `config loaded … N guides: …` lists what the app received.
2. Do its URL patterns match your screen path? `screen("Deals")` is `/Deals`. Make sure you call
   `screen(_:)` (or `.guidelyScreen`) for that screen.
3. Trigger: `manual` guides only start with `startGuide`; `event` guides need `track(name)`;
   `page_load` with a delay waits on the same screen.
4. Frequency: a `once` guide that was already seen (by this user, on any device) will not show
   again. Use **Log out** / `reset()` or a new user id while testing.
5. Targeting rules: user traits, `app.version` (your `CFBundleShortVersionString` or `appVersion`),
   `app.platform` (`ios`), `device.type` (`mobile` / `tablet`).
6. Anchored steps: the target must be tagged with the same Guidely id and be visible on screen.
   `Guidely.shared.registeredTargetIds` lists the ids currently registered. After `target.waitMs`
   the step's fallback applies (`skip`, `show_as_modal`, `end_guide`, or `wait`).
7. Only one exclusive guide (flow, modal, tooltip, survey) runs at a time; others queue behind it.
   Banners, checklists and hotspot-only guides can show alongside.

`Guidely.shared.debugState` returns a snapshot (ready, user, active guide and step, queue, widgets,
pending events, registered targets).

**No events in the dashboard**: check consent, `analytics`, and the project's analytics setting;
events are sent every 2 seconds and when the app backgrounds.

**Local server**: the simulator reaches your Mac at `http://localhost:<port>`; the Android emulator
uses `10.0.2.2`. Allow local networking (see Configure).

## API reference

| API | Description |
|---|---|
| `Guidely.configure(_ options: GuidelyOptions)` | Configure and start (load config, identify stored user, evaluate). |
| `Guidely.shared` | The shared instance. |
| `identify(_ userId:, traits:, account:)` | Identify the user; merges server-held state. |
| `setAccount(_:)`, `updateTraits(_:)` | Update the account / merge traits. |
| `reset()` | Log out: new anonymous id, cleared state, new session. |
| `setConsent(_:)` | `.granted`, `.pending`, `.denied`. |
| `track(_ name:, properties:)` | Custom event. |
| `screen(_ name:)` | Screen view (`page_view`, path `/<name>`). |
| `startGuide(_:stepId:) -> Bool` | Start a guide by key or id. |
| `stopGuide()`, `dismissGuide()` | Stop silently / dismiss the active guide. |
| `activeGuide`, `guides`, `isGuideCompleted(_:)` | Guide state. |
| `checklistProgress(_:)`, `completeChecklistTask(_:taskId:)` | Checklist progress. |
| `openChecklist(_:)`, `closeChecklist(_:)` | Checklist panel. |
| `openResourceCenter()`, `closeResourceCenter()` | Resource center sheet (the messenger's Help tab when Scout is on). |
| `openMessenger(_ tab:)`, `closeMessenger()`, `showNewMessage(_ text:)` | Scout messenger. |
| `refresh()`, `flush() async` | Re-fetch config / send queued events now. |
| `on(_:_:) -> GuidelyListenerToken`, `off(_:)` | Listeners. |
| `anonymousId`, `userId`, `isReady`, `debugState`, `registeredTargetIds` | Introspection. |
| `View.guidelyTarget(_ id:)`, `UIView.guidelyId` | Register targets. |
| `startSessionRecording()`, `stopSessionRecording()` | Force / stop session replay for this session. |
| `isRecording`, `sessionId` | Replay status, current session id. |
| `View.guidelyMask(_:)`, `UIView.guidelyMask` | Mask a view in session recordings. |
| `View.guidelyScreen(_ name:)` | Record a screen on appear. |
| `Guidely.isFeatureEnabled(_:default:)` | Boolean flag value; default for missing or non-boolean flags (any thread). |
| `Guidely.featureValue(_:default:)`, `featureString` / `featureNumber` / `featureBool` / `featureJSON` | Typed flag values. |
| `Guidely.featureDetails(_:)`, `Guidely.allFeatures()` | Evaluation results (reason, rule, variation, experiment). |
| `Guidely.setFlagAttributes(_:)`, `Guidely.setFlagOverrides(_:behaviour:)` | Flag inputs. |
| `Guidely.refreshFlags()`, `Guidely.onFlagsChange(_:) -> GuidelyCancellable` | Refresh / observe flags. |
| `@FeatureFlag`, `@FeatureValue`, `FeatureGate`, `Guidely.flagsStore` | SwiftUI helpers. |
| `GuidelyFlagsClient(sdkKey:…)` | Standalone flags client. |

## Architecture

* `GuidelyCore` (Foundation only, also builds on macOS): tolerant `Codable` models (an unknown enum
  value or a malformed guide never fails the whole config), targeting, URL patterns, versions,
  rollout, frequency, the persisted event queue, the API client, the headless engine
  (`GuidelyEngine`, a port of `packages/sdk-core/src/client.ts`) and the step machine
  (`StepController`, a port of `packages/guide-runtime/src/controller.ts`), plus a small HTML →
  rich-text parser. Feature flags: the pure evaluator (`FlagEvaluator`, a port of
  `packages/flags/src/evaluate.ts`), the thread-safe `GuidelyFlagsClient` (fetch, cache, poll / SSE,
  remote evaluation, decryption, overrides, sticky buckets, usage) and `GuidelyFlagsStore`.
* `Guidely`: the public facade, the target registry, and the SwiftUI overlay hosted in a passthrough
  `UIWindow` above the app (`windowLevel = .normal + 1`, so system alerts stay on top). Touches
  outside SDK content fall through to the app except while a modal/spotlight overlay is showing.


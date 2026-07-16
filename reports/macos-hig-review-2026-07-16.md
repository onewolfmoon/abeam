# macOS App Best Practices Review — Blittie Projector & Blittie Screen

Date: 2026-07-16

Reviewed `BlittieProjector` (sender), `BlittieScreen` (receiver), the shared
`ReceiverProtocol`/`SignalingCore` libraries, the Share Extension, and the
Xcode project settings (Info.plists, sandbox/entitlements build settings,
asset catalogs). Sandbox configuration itself is correct (`ENABLE_APP_SANDBOX`
plus per-target network entitlements synthesized via build settings — no
missing-entitlements issue).

## Accessibility gaps (real, fixable)

- **Icon-only buttons have no accessibility labels.**
  `SendVideoView.swift:73-81` (`gobackward.5`, `goforward.5`, play/pause,
  `stop.fill`) and `ReceiverPickerSheet.swift:18-25` (the `xmark.circle.fill`
  close button) are all `Image(systemName:)` with no `.accessibilityLabel`.
  VoiceOver users get "image" or the raw symbol name instead of "Seek back 5
  seconds," "Play," "Close," etc.
- **Status conveyed by color alone.** The connection-state dot
  (`ContentView.swift:94-103`, `MirrorView.swift:29-31`) is a
  `Circle().fill(statusColor)` with no text/`accessibilityLabel` fallback —
  colorblind users and VoiceOver get nothing. HIG explicitly calls this out:
  never let color be the only signal.

## HIG / native-feel issues

- **`ReceiverPickerSheet`'s close button is an iOS pattern, not macOS.** A
  floating `xmark.circle.fill` in the corner (`ReceiverPickerSheet.swift:18-25`)
  is the iPadOS "card sheet" convention. macOS sheets use a Cancel/Done
  button pair, and critically, **Escape doesn't dismiss this sheet** since
  the button has no `.keyboardShortcut(.cancelAction)`. That's a real,
  noticeable native-feel break — every macOS user expects Esc to back out of
  a sheet.
- **`BlittieScreen`'s Settings scene is empty.** `BlittieScreenApp.swift:70-74`
  gives the app a `Settings { EmptyView() }` scene purely to avoid the
  "no scene" problem. But that means the standard **Cmd+, / "Settings…" menu
  item opens a blank window** — a dead end for anyone who pokes at the app
  menu.
- **`BlittieScreen` is a background daemon wearing a full foreground app's
  menu bar.** It unconditionally sets `.regular` activation policy
  (`BlittieScreenApp.swift:46`) and gets the default File/Edit/View/Window/Help
  menu — none of which do anything meaningful for an app whose entire UI is
  "invisible until a video plays." Worth considering `LSUIElement`
  (menu-bar/background-only presence) or at least trimming the menu via
  `.commands { CommandGroup(replacing: ...) { } }` for the irrelevant items
  (New, Edit, Format, etc.).
- **Pervasive hardcoded point sizes instead of semantic text styles.**
  `.font(.system(size: 12.5))`, `size: 15, weight: .bold`,
  `size: 11, weight: .bold`, etc. appear throughout `ContentView.swift`,
  `MirrorView.swift`, `ReceiverPickerSheet.swift`, and `SendVideoView.swift`.
  These opt out of Dynamic Type entirely — a user who bumps up text size
  system-wide sees zero change in this app. Prefer `.headline`/`.subheadline`/
  `.caption`/`.footnote` (or `.font(.system(.caption, design: .default))` if a
  specific weight is needed) so text actually scales.
- **Manually uppercased section labels** ("ON YOUR NETWORK", "PLAYBACK
  CONTROLS", `ReceiverPickerSheet.swift:91-95`, `SendVideoView.swift:33-35`)
  instead of `Section(header:)`/`.textCase()`. Cosmetically similar, but
  hand-uppercasing strings breaks for locales where that transform isn't
  correct, and doesn't get the system's built-in section-header treatment for
  free.
- **Raw system error strings surfacing to users.** `ReceiverConnection.swift:128,138`
  sets `state = .failed(error.debugDescription)`, and callers like
  `SendVideoView.swift:96,117,129` display `"error: \(error.localizedDescription)"`
  straight to the UI. `debugDescription` is a developer string (things like
  `POSIXErrorCode(61): Connection refused`) — a real Mac app would map known
  cases (host unreachable, connection refused, timeout) to plain language and
  keep the technical string as a details disclosure at most.

## Minor polish

- `BlittieScreen`'s Info.plist has an empty `NSHumanReadableCopyright`
  (`Info.plist:31-32`) — shows blank in the About panel.
- `AccentColor.colorset` exists only under `BlittieScreen/Assets.xcassets`,
  not `BlittieProjector` — inconsistent, though harmless (falls back to
  system blue).
- No app uses `.defaultSize`/`.windowResizability` on its `WindowGroup`, so
  first-launch window size is whatever SwiftUI picks by default rather than
  an intentional size.
- Traditional flat-PNG `AppIcon.appiconset` rather than the macOS 26 Icon
  Composer layered format — not urgent (the system still renders it fine
  under Liquid Glass), but worth a look since `ContentView.swift:17` already
  special-cases macOS 26 for toolbar styling.

## Architecture note (not a bug, but worth naming)

The whole system leans on **polling loops instead of push notifications** —
`AppModel.startPolling()` (`AppModel.swift:79-92`, every 400ms for the app's
entire lifetime), `ReceiverPickerSheet`'s browser-results loop (`:78-84`,
500ms), `MirrorView.watchForExternalStop()` (`:119-136`, 1s), and
`SessionCoordinator`'s several `while !Task.isCancelled { sleep; check }`
loops. The code comments show this was a deliberate call (avoiding
non-Sendable observer closures across actor boundaries), so this isn't a
"wrong" call — but it does mean this app never fully idles: Activity
Monitor's Energy tab will show constant low-level wakeups even when nothing
is happening. `AsyncStream`-based state observation would eliminate that if
it's ever worth revisiting.

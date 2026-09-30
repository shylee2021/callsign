# AGENTS.md

Callsign is a macOS 26+ menu bar app (Swift 6, SwiftUI + AppKit) that draws a tag over each window thumbnail in Mission Control. It depends on the Dock's accessibility tree and private WindowServer/SkyLight APIs, so most behavior can only be confirmed on a live desktop. Sparkle 2 is the only dependency.

## Commands

Run from the repository root. The overrides build ad hoc without the maintainer's signing certificate.

```sh
# Build
xcodebuild build -scheme Callsign -configuration Debug -derivedDataPath /tmp/callsign-dev \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipPackagePluginValidation

# Unit tests: always pass -testPlan Unit
xcodebuild test -scheme Callsign -testPlan Unit -derivedDataPath /tmp/callsign-dev \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipPackagePluginValidation

# One suite or test
xcodebuild test ... -only-testing:CallsignTests/MissionControlProbeTests

# Appcast tool tests
python3 -m unittest discover -s Tools -p 'test_*.py' -v
```

- The scheme's **default** test plan is `Callsign`, which also runs `.integration` tests. Those open real windows, create SkyLight Spaces, and depend on timing. Run them only when the user asks.
- The build needs Xcode 27: `Callsign/AppIcon.icon` was saved with Xcode 27's Icon Composer, and Xcode 26's `actool` fails on it (`Could not open "AppIcon.icon"`). With Xcode 26, add `EXCLUDED_SOURCE_FILE_NAMES=AppIcon.icon ASSETCATALOG_COMPILER_APPICON_NAME=` to build with a generic icon, as CI's macOS 26 job does.
- The project uses synchronized folders: files added under `Callsign/` or `CallsignTests/` join their target without editing `project.pbxproj`.

## Architecture

`AppController` (App/) owns the state and a polling loop. Each iteration calls `MissionControlProbe.poll(configuration:)`, which returns the delay before the next poll: 33 ms while Mission Control is settling or a title read is in flight, 100 ms otherwise, and 500 ms without Accessibility access.

One poll (Detection/):

1. `MissionControlLocator` finds the Dock's AX group with identifier `mc`. If it is missing, Mission Control is closed.
2. `WindowList.onScreen()` reads WindowServer windows (`CGWindowListCopyWindowInfo`).
3. A `ThumbnailSource` produces thumbnail frames:
   - macOS 26: `DockThumbnailSource` reads Dock AX thumbnails. They have no window IDs, so `Thumbnail.matchingWindow` matches by geometry.
   - macOS 27+: `WindowServerThumbnailSource` uses WindowServer frames directly. Titles come from `WindowTitleCache`, which reads AX titles off the main actor and pairs them with window IDs through `_AXUIElementGetWindow`.
4. `ThumbnailStability` hides tags until frames stop moving for two polls. Space changes also restart settling.
5. The probe builds `AppBadge`s (with `AppIdentityCache` for names and icons) and passes them to a `BadgeSink`.

`OverlayManager` (Overlay/) is the real `BadgeSink`. It keeps one non-activating `NSPanel` per window ID, hosting a SwiftUI `BadgeView`. The panels go into a private SkyLight Space so that they do not appear in desktop previews. When that Space cannot be created, they fall back to `.moveToActiveSpace`. The Liquid Glass variant uses `GlassBadgeWindow`, which overrides the private `_hasActiveAppearance`.

Settings/ holds the SwiftUI settings panes and `TagConfiguration`, which persists to `UserDefaults` under the keys in `PreferenceKey`.

Platform/ holds the thin wrappers: `Accessibility` (AX reads with a bounded messaging timeout), `Log` (`os.Logger`, subsystem `com.shylee.Callsign`), and `PrivateAPI`.

## Things to know

- **Concurrency:** the default actor isolation is `MainActor`, with approachable concurrency. Code that must run off the main actor is marked `nonisolated` explicitly (for example `Accessibility`, `PrivateAPI`, and the AX title reads).
- **Private APIs:** every private symbol is resolved in `Platform/PrivateAPI.swift` via `dlsym`, and a missing symbol degrades behavior instead of crashing. Add any new private dependency there and to its header comment. `_hasActiveAppearance` is the one exception because AppKit calls it.
- **Preference keys:** `PreferenceKey` values are on-disk keys. Renaming one silently resets users' settings.
- **Test seams:** `MissionControlProbe.init` injects the thumbnail source, window list, locator, trust check, and `BadgeSink`. Unit tests script Mission Control through these instead of touching the desktop (see `MissionControlProbeTests`). The app delegate skips monitoring and Sparkle when running under XCTest or previews.
- **Tests:** tests use Swift Testing (`@Suite`, `@Test`, `#expect`). Tag any test that needs real windows, private SkyLight state, or wall-clock timing with `.tags(.integration)`.
- **`ponytail:` comments** mark deliberate simplifications and say when to revisit them. Keep them accurate when you touch that code.
- **Comments** explain why, not what; match the existing density.
- **Debugging:** run `log stream --predicate 'subsystem == "com.shylee.Callsign"'`. Settings > General > Record diagnostics captures a report of the Dock AX tree and windows once Mission Control settles.
- **Xcode 26 compiler crash:** pass SwiftUI binding setters as closures (`set: { controller.setLaunchAtLogin($0) }`), not method references (`set: controller.setLaunchAtLogin`). Swift 6.2 in Xcode 26.6 crashes in IRGen on the reference form. Xcode 27 builds it fine, so only CI's macOS 26 job would catch it.

## Boundaries

- Do not run the `Callsign` test plan, or open or drive Mission Control, unless asked. A build or unit test does not show that tags work in Mission Control, so say what is unverified.
- Do not change signing settings, bundle identifiers, `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` (the release workflow sets both), or the Sparkle keys in `Info.plist`, unless the task is about them.
- Do not commit, push, open PRs, push `v*` tags (they publish a release), or run the Release workflow unless asked. Never push to `main` directly, even though the maintainer's account can bypass its ruleset.
- The contributor workflow (branch names, PRs, verification) is in [CONTRIBUTING.md](CONTRIBUTING.md).

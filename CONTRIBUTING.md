# Contributing to Callsign

This guide explains how to report problems, propose changes, and send pull requests, and how to build and test Callsign locally. Coding agents should also read [AGENTS.md](AGENTS.md).

## Before you start

Callsign draws its tags by reading the Dock's accessibility tree and calling private macOS APIs (see [Caveats](README.md#caveats)). Its behavior depends on the macOS version, displays, Spaces, and Mission Control settings, so an issue or a PR is most useful when it says exactly which setup it was checked on.

## Issues

- Search [open and closed issues](https://github.com/shylee2021/callsign/issues?q=is%3Aissue) and the [known limitations](README.md#known-limitations) first.
- Report bugs with the [bug report form](https://github.com/shylee2021/callsign/issues/new?template=bug_report.yml), one problem per issue.
- Suggest features with the [feature request form](https://github.com/shylee2021/callsign/issues/new?template=feature_request.yml). The [roadmap](README.md#roadmap) lists what is already planned.
- For anything else, including questions, open a [blank issue](https://github.com/shylee2021/callsign/issues/new). The repository does not use GitHub Discussions.
- To work on an existing issue, comment on it first so that work is not duplicated. Issues labeled [`good first issue`](https://github.com/shylee2021/callsign/labels/good%20first%20issue) or [`help wanted`](https://github.com/shylee2021/callsign/labels/help%20wanted) are good starting points.

## Pull requests

- An open issue is a proposal, not approval to implement it. Agree on the scope with the maintainer in the issue before starting substantial features, new dependencies, or broad refactoring. Small, obvious fixes do not need a separate issue.
- Branch from `main` using `<type>/<short-kebab-case-description>`, where the type is `feat`, `fix`, `docs`, or `chore` (including CI and build changes): for example, `feat/per-app-tags` or `fix/grouped-window-labels`. An issue number is optional, e.g. `fix/42-grouped-window-labels`.
- Open one focused PR against `main` and fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Review your own diff and leave out unrelated changes. Keep unfinished work as a draft.
- WIP commits are fine; there is no need to squash them during review. The maintainer squash-merges PRs after review and passing CI, so write a PR title and description that work as the final commit. Delete the branch after it is merged rather than reusing it.
- Match the surrounding Swift style. The project has no lint or format configuration yet; repository-wide formatting changes belong in a separate PR.
- Contributions are licensed under the project's [MIT license](LICENSE).

## AI assistance

Callsign itself was built with substantial help from AI, and AI-assisted contributions are welcome. They are held to the same standard as any other contribution:

- Fill in the PR template's AI assistance section with the tools you used and what they did.
- Review every change you submit, and be ready to explain it and answer review questions yourself.
- Report only checks you actually ran. For Callsign, a successful build does not show that tags behave correctly in Mission Control.

## Local builds and checks

Building needs Xcode 27. The app icon, `Callsign/AppIcon.icon`, was saved with Xcode 27's Icon Composer, and Xcode 26's asset catalog compiler (`actool`) fails on it with `Could not open "AppIcon.icon"`. The Swift code itself also builds with Xcode 26. The appcast tools and their tests need only Python 3.

Open `Callsign.xcodeproj`, or run these commands from the repository root. The command-line signing overrides build ad hoc, without the maintainer's certificates; do not commit changes to the project's signing settings.

```sh
xcodebuild build -scheme Callsign -configuration Debug -derivedDataPath /tmp/callsign-dev \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipPackagePluginValidation

xcodebuild test -scheme Callsign -testPlan Unit -derivedDataPath /tmp/callsign-dev \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipPackagePluginValidation

python3 -m unittest discover -s Tools -p 'test_*.py' -v
```

The app is built at `/tmp/callsign-dev/Build/Products/Debug/Callsign.app`. An ad hoc signature changes with every build, so you may need to grant Accessibility access again after rebuilding.

With Xcode 26, leave the icon out by adding `EXCLUDED_SOURCE_FILE_NAMES=AppIcon.icon ASSETCATALOG_COMPILER_APPICON_NAME=` to the `xcodebuild` commands, as CI's macOS 26 job does. The app then builds and runs with a generic icon.

### Test plans

The `Callsign` scheme has two test plans:

- `Unit` skips tests tagged `.integration` (see [`TestTags.swift`](CallsignTests/TestTags.swift)). This is the routine check, and it is what CI runs.
- `Callsign` runs every test, including integration tests that need a live desktop session: real windows, private SkyLight state, or wall-clock timing. It is the scheme's default, so Xcode's Product > Test (⌘U) and `xcodebuild test` without `-testPlan` run it.

Tag new tests that need a live desktop with `.tags(.integration)` so that the `Unit` plan skips them.

### CI

CI runs the `Unit` plan on macOS 27 with Xcode 27, and on macOS 26 with Xcode 26 without the app icon. The macOS 26 job is advisory: its failure does not fail the workflow. CI also runs the appcast tool tests.

## Verification

Run the checks relevant to your change:

- Swift or project changes: build and run the `Unit` plan.
- Changes under `Tools/`: run the appcast tool tests.
- Docs and template changes: check the syntax and links, and review the diff. An app build is unnecessary.

For behavior changes, add regression coverage where practical and manually verify the affected Mission Control behavior. Record the Mac model, macOS version, and relevant display, Spaces, grouping, and Accessibility settings. State untested cases honestly; a successful build or unit test does not show that a real desktop interaction works. Redact private window titles, document contents, and file paths before sharing screenshots, recordings, or logs.

## Releases

Releases are made by the maintainer, not through ordinary PRs.

- Pushing a `v*` tag (`vX.Y.Z` or `vX.Y.Z-beta.N`) builds and publishes a GitHub release and redeploys the appcast. Running the Release workflow manually only rebuilds and redeploys the appcast from existing releases.
- The release build sets `MARKETING_VERSION` from the tag and `CURRENT_PROJECT_VERSION` from the workflow run number. Do not bump the versions in the project.
- Leave the bundle identifiers, signing settings, and Sparkle feed URL and public key (`SUFeedURL` and `SUPublicEDKey` in `Callsign/Info.plist`) unchanged unless the change is specifically about them.

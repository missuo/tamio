# AGENTS.md

Guidance for coding agents (Claude Code, Codex, and the like) working in this
repository. Read it before changing anything; `DESIGN.md` has the product plan.

## What this is

Tamio is a native SSH client for macOS: a Ghostty terminal, dual-pane SFTP,
live status for every server, end-to-end encrypted iCloud sync, and an MCP
server that lets AI agents work on the user's servers with their approval.
It is a native macOS app (SwiftUI on AppKit, Swift 6), macOS 14 or later,
bundle id `sb.moe.tamio`. The iOS and iPadOS app (`Application/TamioMobile`,
SwiftUI on UIKit, iOS 17 or later) shares the Foundation packages with it and
is being brought up to the Mac app's features; it is not shipped yet.

## Layout

| Path | What is there |
|---|---|
| `Application/Tamio` | The Mac app. `Interface/` holds the pages (Home, Servers, Files, Settings…), `Mac/` the AppKit side (windows and their material, alerts and panels, the menu bar item, Sparkle), `project.yml` the XcodeGen spec |
| `Application/TamioMobile` | The iOS and iPadOS app: a tab bar on iPhone, the sidebar on iPad. `project.yml` is its XcodeGen spec; `TamioMobile.xcworkspace` at the root holds it with the packages. Its `Resources/Localizable.xcstrings` is its own copy of the Mac catalog plus the iOS-only strings |
| `Foundation/TamioModule` | The app's core: store, sync, SFTP browsing and transfers, the MCP server (`Agent/`) |
| `Foundation/TamioDesign` | Design tokens and shared controls (colours, rows, `RXRowLayout`) |
| `Foundation/TamioTerminal` | The Ghostty terminal and its settings catalog |
| `Foundation/MachineStatus`, `MachineStatusView` | Reading a server's status over SSH, and its cards |
| `External/` | Vendored NSRemoteShell (libssh2), CodeMirrorUI; Sparkle is fetched into `External/Sparkle` by `Workflow/Scripts/sparkle.sh` |
| `Resources/Tamio.icon` | The app icon (Icon Composer) |
| `skills/tamio` | The skill agents install to use Tamio's MCP server |
| `website/` | tamio.sh, a static site on Cloudflare Workers |
| `Workflow/Scripts` | Build, release, appcast and signing scripts |

## Build and test

```sh
bash Workflow/Scripts/build-macos.sh                      # Debug build, signed ad hoc
cd Application/Tamio && xcodegen generate                 # after editing project.yml
swift test --package-path Foundation/TamioModule
swift test --package-path Foundation/MachineStatus
swift test --package-path Foundation/TamioTerminal
bash Workflow/Scripts/fmt.sh                              # swiftformat, Swift 6
```

The iOS app builds from the workspace for a simulator (pick one with
`xcrun simctl list devices available`); regenerate its project with
`cd Application/TamioMobile && xcodegen generate` after editing its
`project.yml`:

```sh
xcodebuild -workspace TamioMobile.xcworkspace -scheme TamioMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/dd-ios CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted /tmp/dd-ios/Build/Products/Debug-iphonesimulator/Tamio.app
xcrun simctl launch booted sb.moe.tamio.debug -licenseAgreed YES
```

A debug build started with `TAMIO_PREVIEW_SERVER=user@host -p port` and
`TAMIO_PREVIEW_KEY=<private key>` (as `SIMCTL_CHILD_` environment of
`simctl launch`) has that server in its store, and `TAMIO_PREVIEW_OPEN=terminal`
opens its terminal: a throwaway `sshd` on the Mac is enough to see live
status and a shell without typing into the simulator.

- **Never sign locally.** Local builds are ad hoc. Developer ID signing,
  notarization and Sparkle signing happen only in GitHub Actions.
- **Never drive or quit the user's own Tamio.** To test the UI, build a copy
  with its own bundle id (for example `sb.moe.tamio.uitest`) and use that.
- Run the module tests after changing `Foundation/`; build the app after
  changing `Application/`. A change to a shared package or `TamioDesign`
  should build for both the Mac and the simulator.

## Releasing

1. Put the changes under `## [Unreleased]` in `CHANGELOG.md` as you make them,
   in the Keep a Changelog shape: `### Added`, `### Changed`, `### Fixed`,
   `### Removed`, each item a bullet that opens with a bold phrase saying what
   changed for the user, then the detail. Never group by area of the app.
2. To release, add `## [x.y.z] - YYYY-MM-DD` under Unreleased, set
   `MARKETING_VERSION` in `Application/Tamio/project.yml`, run `xcodegen
   generate`, commit, and push the tag `vx.y.z`.
3. `.github/workflows/release.yml` builds, signs, notarizes, writes the
   Sparkle appcast and publishes the release as the latest, with that
   changelog section as its notes. A tag with no section is not built.
4. Check the published DMG: Gatekeeper accepts it, the app carries the iCloud
   entitlements, and the appcast's EdDSA signature verifies.

The Homebrew cask lives in `OwO-Network/homebrew-brew` (`Casks/tamio.rb`); its
scheduled script bumps the version and checksum.

## The website

`website/public` is served by `website/src/index.js` on Cloudflare Workers.
`npm run dev` in `website/` previews it at http://localhost:8787 and `npm run
deploy` publishes it to tamio.sh. The window on the page is drawn by
`public/demo.js` and `demo.css` to the app's own measurements and colours
(`Foundation/TamioDesign/Sources/TamioDesign/Tokens.swift`): keep the two in
step, and never put screenshots of the app on the site.

## Rules of the house

- **Commits:** Conventional Commits (`feat(sync): …`, `fix(ui): …`), imperative,
  a body that says why. No `Co-Authored-By` trailers.
- **Secrets:** never print or commit passwords, private keys, `.p8`/`.p12`
  files or tokens. The MCP server never returns a password, private key or
  passphrase, and nothing should change that.
- **Text is never cut off.** No ellipsis truncation in the UI: show text whole
  (wrap it) or leave it out and put it in a tooltip. Settings rows use
  `RXRowLayout`, which moves a wide control under its label.
- **Agents' history:** every action an agent takes through MCP is recorded per
  server, grouped by the `task` the agent names. Keep new tools recording
  their actions the same way.
- **Comments and copy:** plain, specific English; comments say why, not what.
  Match the surrounding code's style and density.
- **Contributors:** Settings › About › Acknowledgements lists every GitHub
  contributor, as `@login`, in the order `gh api repos/missuo/tamio/contributors`
  gives (`AcknowledgementSettings` in `Interface/Settings/SettingsView.swift`).
  When a pull request from someone not yet listed is merged, add them in the
  same change; before each release, check the list against that command.
- **Upstream:** Tamio descends from mizorewww/catussh and Lakr233/Rayon;
  `Workflow/Scripts/tamio-rename.py` ports upstream changes.

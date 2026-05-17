<p align="center">
  <img src="icon-source.png" alt="BuildBar" width="128" />
</p>

<h1 align="center">BuildBar</h1>

<p align="center">
  <strong>The macOS menu bar cockpit for mobile & frontend engineers.</strong><br/>
  EAS Builds &middot; Vercel Deployments &middot; GitHub Actions — all in one dropdown.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="macOS 13+"/>
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="Swift 5.9"/>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"/>
</p>

---

## Why BuildBar

You ship Expo apps and Next.js frontends. That means you're constantly switching between:

- **expo.dev** to check EAS build status
- **vercel.com** to see if the latest deploy landed
- **GitHub Actions** to watch CI

BuildBar puts all three in your menu bar. One click, no browser tabs, no context-switching. It polls quietly in the background and sends you a native macOS notification the moment something changes.

---

## Tabs

### EAS Builds

Live dashboard for every Expo project you add.

- Multi-project — add as many folders as you ship from. Each gets a project-color chip.
- Live status badges with elapsed time (`Building · 4m 12s`)
- Filter by platform (iOS / Android), status (Building / Done / Failed), or free-text search
- Group by project or view as a flat chronological feed
- Rich per-build actions from the `···` menu or right-click:

  | Action | Detail |
  |--------|--------|
  | Copy install URL | One click to clipboard |
  | Show QR code | Scan and install on device |
  | Download artifact | Downloads and reveals in Finder |
  | Install via adb | Downloads APK and runs `adb install` |
  | View logs | Opens the build page on expo.dev |
  | Copy commit hash | Copies the full git hash |
  | Open commit on GitHub | Resolves the remote URL and opens the commit |
  | Cancel build | Cancels an in-flight EAS build |

- **EAS Updates** viewer — right-click a project → "View latest updates" to inspect published update branches and channels
- Auth-expired banner when `eas login` is needed

### Vercel

Deployment monitoring via the [Vercel REST API](https://vercel.com/docs/rest-api).

- See your last 15 deployments across personal and team accounts
- Filter by name, branch, target, commit message, or author
- Click to open the deployment URL or the Vercel inspector
- **One-time setup** — paste a personal access token (create one at [vercel.com/account/tokens](https://vercel.com/account/tokens))

### GitHub Actions

Workflow run monitoring via the `gh` CLI.

- Add `owner/repo` pairs — uses your existing `gh` auth, no token to manage
- Workflow name, branch, event type, status, and conclusion
- Click to open the run on GitHub
- Native notification when a workflow passes or fails

---

## Shared Features

| Feature | Detail |
|---------|--------|
| Native notifications | Build finished, deploy ready, workflow passed/failed — click the notification to open the URL |
| Disk cache | Menu opens instantly with cached data while a background refresh runs |
| Exponential backoff | When every project fails, polling slows down so you don't hammer APIs |
| Pause polling | Footer button to pause/resume polling per tab |
| Configurable interval | EAS tab: 15s / 30s / 1m / 5m |
| Launch at login | Gear menu → toggle on (requires `.app` bundle) |
| Per-project colors | 10-color palette per project and repo so chips are scannable |
| Rename projects | Right-click → Rename, or change the color tag |

---

## Requirements

- **macOS 13** (Ventura) or later
- **Xcode** — full install, not just Command Line Tools (SwiftUI needs the framework bundle)
- **EAS tab**: [`eas-cli`](https://github.com/expo/eas-cli) installed globally and logged in
  ```bash
  npm i -g eas-cli && eas login
  ```
- **Actions tab**: [GitHub CLI](https://cli.github.com) installed and authenticated
  ```bash
  brew install gh && gh auth login
  ```
- **Vercel tab**: A [personal access token](https://vercel.com/account/tokens) with "Full Account" scope

---

## Quick Start

```bash
git clone https://github.com/YOUR_USER/BuildBar.git
cd BuildBar
./run.sh             # debug build, wraps in .app, launches
./run.sh release     # release (optimized) build
```

A hammer icon appears in your menu bar. Click it, switch between tabs, and add your projects / token / repos.

> **Why `run.sh` instead of `swift run`?** macOS notifications and Launch at Login require a real `.app` bundle with a bundle identifier. `swift run` launches the raw binary from `.build/debug/` — no bundle, no notifications. `run.sh` builds the binary, wraps it in a proper `BuildBar.app` with icons and `Info.plist`, and `open`s it.

### Install permanently

```bash
./run.sh release
mv BuildBar.app /Applications/
open /Applications/BuildBar.app
# Click the gear icon → "Launch at login"
```

---

## Architecture

```
Sources/BuildBar/
├── App.swift                 @main entry point + AppDelegate (notifications, .accessory activation)
├── Models.swift              EASBuild, Project, ProjectColor, AnnotatedBuild, CacheSnapshot
├── EASService.swift          Shells out to `eas build:list --json`
├── EASUpdate.swift           EAS Updates model + popover
├── Watcher.swift             EAS polling engine, disk cache, exponential backoff, tick timer
├── Actions.swift             Shell helpers: cancel build, download artifact, adb install, git remote
├── Vercel.swift              Vercel REST API client + VercelWatcher
├── VercelView.swift          Vercel tab UI
├── GitHubActions.swift       `gh` CLI client + GitHubWatcher
├── GitHubActionsView.swift   Actions tab UI
├── LaunchAtLogin.swift       SMAppService wrapper
├── QRCodeView.swift          CoreImage QR code generator
└── Views.swift               Main menu UI, tab bar, project list, build rows, filter chips
```

Each tab runs an independent polling loop. Pollers sleep when paused. The EAS poller applies exponential backoff (up to 16× base interval) when every project returns an error — no retry storms.

---

## Distribution

The `run.sh`-generated `.app` is unsigned and will be blocked by Gatekeeper on other Macs ("damaged" or "cannot be opened"). To share with teammates:

### Sign with Developer ID

```bash
./run.sh release

# Find your identity
security find-identity -v -p codesigning

# Sign with hardened runtime (required for notarization)
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  BuildBar.app
```

### Notarize

```bash
ditto -c -k --keepParent BuildBar.app BuildBar.zip

xcrun notarytool store-credentials "BuildBar-Notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "abcd-efgh-ijkl-mnop"

xcrun notarytool submit BuildBar.zip \
  --keychain-profile "BuildBar-Notary" \
  --wait

xcrun stapler staple BuildBar.app
```

After stapling, re-zip and share. Teammates can drag to `/Applications` with no Gatekeeper warnings.

---

## Troubleshooting

<details>
<summary><strong>command not found: eas / gh</strong></summary>

The app runs CLIs via a login shell (`zsh -l -c`), so it reads your `.zshrc` / `.zprofile`. Verify:

```bash
which eas   # should print a path
which gh    # should print a path
```

If you use Volta, asdf, or nvm for Node, make sure the init lines are in `.zprofile` (not `.zshrc`), since login shells read `.zprofile` first.
</details>

<details>
<summary><strong>No notifications</strong></summary>

On first launch, macOS prompts for notification permission. If you missed it: **System Settings → Notifications → BuildBar**. Notifications only work when launched from a `.app` bundle (via `run.sh`), never from raw `swift run`.
</details>

<details>
<summary><strong>Vercel says Unauthorized</strong></summary>

Token is expired or missing scopes. Create a new one at [vercel.com/account/tokens](https://vercel.com/account/tokens) with "Full Account" scope, then update it in the Vercel tab.
</details>

<details>
<summary><strong>GitHub Actions shows "Install GitHub CLI"</strong></summary>

```bash
brew install gh && gh auth login
```

Then click the refresh button in the Actions tab.
</details>

<details>
<summary><strong>Stuck on "Loading…" in EAS tab</strong></summary>

Run the command manually to see the real error:

```bash
cd /path/to/your/expo-project
eas build:list --json --non-interactive --limit=10
```
</details>

<details>
<summary><strong>Launch at login is greyed out</strong></summary>

You're running the raw binary via `swift run` (no bundle). Re-launch via `./run.sh`.
</details>

---

## License

MIT

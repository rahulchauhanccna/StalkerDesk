# Arya IPTV Portal

A native macOS IPTV and on-demand client for Stalker / Ministra middleware portals, built for Apple Silicon MacBooks with SwiftUI, AVPlayer, and an optional VLCKit fallback. It emulates the MAG 250/254/322 device handshake, including a user-configurable virtual MAC, device identity, timezone, persistent portal profiles, live channel directory, EPG, movie and web-series catalogs, and header-authenticated stream playback.

> Use this software only with portals and services you are authorized to access. It ships no channels, credentials, playlists, or DRM circumvention.

## Highlights

- **Three content modes** — **Live TV**, **Movies**, and **Web Series**, each with its own portal categories.
- **Three-column UI** — categories → channels/posters → player + EPG or title details.
- **Reliable player-only fullscreen** — opens a dedicated borderless, screen-covering player window with minimal Apple TV-style controls and a stable exit path.
- **Multi-portal manager** — add, edit, delete, switch, default portal; per-portal MAC, device ID, serial, timezone and optional account credentials.
- **Real Stalker/Ministra handshake** — endpoint discovery, `action=handshake`, profile authentication, cookie jar, optional `do_auth`, automatic single-flight token refresh on 401 or local expiry.
- **Channel directory** — `get_genres`, paginated `get_ordered_list`, concurrent page loading, search.
- **Live EPG** — bulk `get_epg_info` with `get_short_epg` fallback, live progress and "up next".
- **Movies and series** — VOD categories, poster/thumbnail grid, movie playback, series seasons, episode lists, and episode playback (`get_categories`, `get_ordered_list`, `create_link`, `get_episode_stream`).
- **Artwork and sorting** — Stalker `screenshot_uri` thumbnails and sorting by recently added, title, year, or rating.
- **Resume playback** — movies and series episodes remember their last position and offer Resume / Continue Watching.
- **Fullscreen polish** — controls auto-hide during playback and a seek/progress bar is available for VOD.
- **Stream resolution** — `create_link`, localhost rewriting, cookie/Authorization/Referer injection into playback.
- **Native playback** — AVPlayer with PiP, fullscreen, aspect ratio (16:9 / fit / zoom), keyboard channel switching, automatic VLCKit fallback for raw MPEG-TS when VLCKit is linked.
- **macOS-native persistence** — Core Data for profiles (Ventura-compatible; SwiftData requires macOS 14) and the macOS Keychain for passwords and resumable session tokens.
- **No third-party runtime dependencies** for the base app.

## Requirements

- macOS 13 Ventura or newer (Apple Silicon recommended; universal source).
- Xcode 15+ **or** the Command Line Tools with a compatible macOS SDK.
- Optional: [VLCKit](https://code.videolan.org/videolan/VLCKit) for raw MPEG-TS / MPEG-2 streams.

## Build and run

```bash
cd StalkerDesk
swift build
./scripts/build-app.sh
open ".build/Arya IPTV Portal.app"
```

The build script creates a self-contained `Arya IPTV Portal.app` in `.build/`, copies the app icon and `Info.plist`, and ad-hoc signs it. Use `CONFIGURATION=debug` for a debug bundle.

To create a shippable DMG:

```bash
./scripts/build-dmg.sh
open dist
```

For distribution to other Macs, sign with a Developer ID Application certificate and notarize:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="arya-notary" \
./scripts/build-dmg.sh
```

An ad-hoc DMG still runs locally, but Gatekeeper on another Mac will require right-click > Open (or removing the quarantine attribute).

Run the headless protocol checks (no XCTest/Xcode project required):

```bash
swift run StalkerDeskChecks
```

### Command Line Tools note

Some Command Line Tools installations expose a macOS 27 SDK but do not ship the SwiftUI macro plugin. If the default `swift build` fails with `SwiftUIMacros ... not found`, select the older SDK that includes the plugin:

```bash
STALKERDESK_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
./scripts/build-app.sh
```

If your environment also needs SwiftPM sandbox or cache overrides:

```bash
STALKERDESK_SWIFT_FLAGS="--disable-sandbox --manifest-cache local" \
./scripts/build-app.sh
```

## Project layout

| Path | Purpose |
| --- | --- |
| [`Sources/StalkerDeskCore/Networking/StalkerClient.swift`](Sources/StalkerDeskCore/Networking/StalkerClient.swift) | Actor-isolated Stalker client: endpoint discovery, handshake, auth, cookies, retries, token refresh |
| [`Sources/StalkerDeskCore/Networking/StalkerClient+API.swift`](Sources/StalkerDeskCore/Networking/StalkerClient+API.swift) | Genres, channels, EPG, `create_link` and stream header resolution |
| [`Sources/StalkerDeskCore/Networking/StalkerPayloadParser.swift`](Sources/StalkerDeskCore/Networking/StalkerPayloadParser.swift) | Defensive mapping of Stalker JSON into typed models |
| [`Sources/StalkerDeskCore/Models/PortalModel.swift`](Sources/StalkerDeskCore/Models/PortalModel.swift) | Portal profile, MAC validator/formatter, MAG device identity, portal URL resolver |
| [`Sources/StalkerDeskCore/Models/IPTVModels.swift`](Sources/StalkerDeskCore/Models/IPTVModels.swift) | Genres, channels, EPG, account, session, stream and playback models |
| [`Sources/StalkerDeskCore/Models/PersistenceController.swift`](Sources/StalkerDeskCore/Models/PersistenceController.swift) | Programmatic Core Data stack |
| [`Sources/StalkerDeskCore/Models/KeychainStore.swift`](Sources/StalkerDeskCore/Models/KeychainStore.swift) | Keychain passwords and resumable session token cache |
| [`Sources/StalkerDeskCore/Playback/PlayerCoordinator.swift`](Sources/StalkerDeskCore/Playback/PlayerCoordinator.swift) | Engine abstraction, fallback, PiP/fullscreen/aspect/keyboard controls |
| [`Sources/StalkerDeskCore/Playback/AVPlayerEngine.swift`](Sources/StalkerDeskCore/Playback/AVPlayerEngine.swift) | AVPlayerLayer engine with header injection and PiP |
| [`Sources/StalkerDeskCore/Playback/VLCPlaybackEngine.swift`](Sources/StalkerDeskCore/Playback/VLCPlaybackEngine.swift) | Optional VLCKit fallback, compiled only when VLCKit is present |
| [`Sources/StalkerDesk/AppState.swift`](Sources/StalkerDesk/AppState.swift) | Connection, catalog, EPG, cancellation and playback orchestration |
| [`Sources/StalkerDesk/Views/ContentView.swift`](Sources/StalkerDesk/Views/ContentView.swift) | Apple TV-style browse/detail shell |
| [`Sources/StalkerDesk/Views/PlayerPane.swift`](Sources/StalkerDesk/Views/PlayerPane.swift) | Live video stage, controls, EPG |
| [`Sources/StalkerDesk/Views/MediaCatalog.swift`](Sources/StalkerDesk/Views/MediaCatalog.swift) | Movie/series grids, title detail, seasons/episodes, fullscreen player |
| [`Sources/StalkerDesk/TVTheme.swift`](Sources/StalkerDesk/TVTheme.swift) | Apple TV-style visual system, cards and hover treatment |
| [`Sources/StalkerDesk/FullscreenWindowController.swift`](Sources/StalkerDesk/FullscreenWindowController.swift) | Dedicated borderless fullscreen player window |
| [`Sources/StalkerDesk/AppLog.swift`](Sources/StalkerDesk/AppLog.swift) | Local, redacted diagnostics log |
| [`Sources/StalkerDesk/Views/PortalEditorView.swift`](Sources/StalkerDesk/Views/PortalEditorView.swift) | Portal configuration form with live MAC validation |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Deep dive: protocol, data models, concurrency, failure handling |

## Configuring a portal

1. Click **Add Portal**.
2. Enter the portal URL. Accepted forms include:
   - `http://host/c/`
   - `http://host/stalker_portal/server/load.php`
   - `http://host/server/load.php`
   - `http://host/portal.php`
3. Enter the MAC address provisioned by the provider. The form formats and validates `AA:BB:CC:DD:EE:FF` as you type and warns if the address is outside the MAG `00:1A:79` OUI.
4. Device ID and serial are deterministically generated from the MAC; override them if the provider binds a specific identity.
5. Pick the portal timezone (sent in the Stalker cookie) and save.
6. Optionally add a username/password if the portal implements `do_auth`. Credentials are kept in the Keychain and are only sent when a username is present.

## Content modes

Use the segmented **Live / Movies / Series** switch at the top of the sidebar.

- **Live** loads `get_genres` and `get_ordered_list` channels; the player is paired with EPG.
- **Movies** loads VOD categories and filters catalog items to movies (`is_series != 1`), showing a poster grid and movie details.
- **Series** uses the same VOD categories and filters to series (`is_series = 1`). Selecting a series loads seasons, then episodes. Selecting an episode resolves and plays it.

VOD playback supports the common Stalker variants: a playable `cmd` on the catalog item, `get_episode_stream`, and the legacy `create_link` with `/media/file_<id>.mpg`.

## Fullscreen

Click the fullscreen button in the player controls (or press **F**). The app opens a dedicated, screen-covering player window with title, transport controls, volume, aspect ratio, PiP and an explicit **Exit Fullscreen** button. Exit via that button, **F**, or **Escape**; the browse UI and playback surface are restored afterward. This avoids AppKit native-fullscreen conflicts with SwiftUI player-surface changes.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| ↑ | Next channel |
| ↓ | Previous channel |
| Space | Play / pause |
| ← / → | Seek 10 seconds |
| F | Fullscreen |
| P | Picture in picture (AVPlayer) |
| M | Mute |

## Troubleshooting

**HTTP 429 / rate-limited.** The portal is throttling rapid API requests. The app now stops on a 429 instead of probing more endpoints. Wait about a minute and use **Refresh** or **Reconnect**. Avoid repeatedly reconnecting.

**“No token was returned” on a bare host.** The app follows the portal landing page redirect (for example to /stalker_portal/c/) and derives the real /stalker_portal/server/load.php endpoint. If the provider gives a full portal path, entering it directly is also fine.

**“The portal rejected this device.”** The portal received the handshake but does not recognize the MAC/device. Confirm the MAC is provisioned for your account. The app normally derives device ID/serial from the MAC; if you change the MAC in the editor, the derived values are updated automatically. If your provider binds a custom device ID/serial, enter those exact values.

**Connected, but no categories/channels.** A mismatched device identity can pass `handshake` but make `get_profile` return an empty object and `get_genres` return `Authorization failed`. The current build detects this, repairs an app-generated stale identity once, and reconnects. If it still happens, open **Manage Portals → Edit**, click **Generate**, and save. The app also retries category requests when the portal returns HTTP 429 and shows a **Retry Categories** action.

**Diagnostics.** The app writes a local diagnostic log (no tokens, cookies, passwords or stream URLs) to `~/Library/Logs/AryaIPTVPortal/AryaIPTVPortal.log`.

**Live connection diagnostic.** A headless diagnostic is available without changing the app:

```bash
STALKERDESK_LIVE_CHECK=1 \
STALKERDESK_LIVE_PORTAL='http://example.com/' \
STALKERDESK_LIVE_MAC='00:1A:79:XX:XX:XX' \
STALKERDESK_LIVE_TIMEZONE='America/Los_Angeles' \
swift run StalkerDeskChecks
```

## Video catalog troubleshooting

**Movies/Series is empty.** The portal may not implement `get_categories` for VOD, or your subscription may not include that library. Switch back to Live and retry; the app logs the exact HTTP status in its diagnostics.

**Some VOD categories are empty.** Categories returned by the portal can be mixed; Movies and Series filter the returned titles by the portal's `is_series` flag. If a category only contains the other type, it will correctly appear empty.

## Apple TV / tvOS direction

The catalog uses a ten-foot interface: a dark cinematic background, large Live TV / Movies / Web Series tabs, a horizontal category rail, poster and channel shelves, and a full-width detail/player stage with large hit targets.

The package currently targets macOS because player presentation uses AppKit. A future tvOS target can reuse the core models, networking, Core Data, Keychain, AVPlayer logic, TVTheme, card layouts and browse/detail flow. The required port steps are: add a tvOS target, replace PlayerSurface and FullscreenWindowController with AVPlayerViewController, add a tvOS app entry point and focus handling, adapt portal management to tvOS navigation, and revalidate Keychain/Core Data/ATS on tvOS.

## VLCKit fallback

The base app only uses AVPlayer. To play raw MPEG-TS/MPEG-2 without HLS remuxing, add VLCKit to the app target:

1. Install VLCKit via CocoaPods (`pod 'VLCKit', '~> 3.3'`) or download the VLCKit XCFramework.
2. Link `VLCKit.framework` and its system dependencies.
3. Rebuild. `#if canImport(VLCKit)` activates [`VLCPlaybackEngine.swift`](Sources/StalkerDeskCore/Playback/VLCPlaybackEngine.swift). Automatic engine selection prefers VLCKit for `.ts`/`.mpegts`/`.m2ts` URLs, and AVPlayer failures fall back to VLCKit.

VLCKit is LGPLv2.1-or-later. Review its linking/licensing obligations before distribution. PiP is implemented for AVPlayer only.

## Security and operational notes

- Portal HTTP traffic is plain text in most deployments. The app enables ATS arbitrary loads so HTTP portals work; this is intentionally scoped to the app's own network requests (no in-app browser). Prefer HTTPS portals.
- Passwords and cached session tokens use `kSecAttrAccessibleAfterFirstUnlock` Keychain items. Tokens are never written to Core Data or UserDefaults.
- The Stalker token is held in an actor and an encrypted Keychain cache, refreshed on 401/expiry, and forwarded to stream requests as cookies and a bearer header.
- App Sandbox entitlements are provided in [`Resources/StalkerDesk.entitlements`](Resources/StalkerDesk.entitlements) for distribution builds. The ad-hoc developer bundle is unsandboxed.
- Live TV, movies and series catalogs are supported. Catch-up playback, recording and DRM are intentionally out of scope. VOD support is best-effort across Stalker variants.

## Legal

This is an independent interoperability client for Stalker/Ministra portals. It does not include, host, or provide access to any media. You are responsible for complying with your provider's terms, local law, and copyright. VLCKit and any other third-party components remain under their own licenses.

The source in this repository is provided under the MIT license (see [`LICENSE`](LICENSE)).

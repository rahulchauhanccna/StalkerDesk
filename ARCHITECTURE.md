# Arya IPTV Portal Architecture

This document describes the implementation in this repository. It is intended for engineers extending the client or porting parts of it to another platform.

## 1. Goals and constraints

- Native macOS 13+, SwiftUI, Apple Silicon first.
- StbEmu-class interoperability with Stalker/Ministra portals and MAG device identities.
- No service assumptions: the portal URL can be /c/, /portal.php, or an explicit server/load.php endpoint; the client discovers which one works.
- No credential leaks: tokens and passwords stay in memory or the Keychain.
- Playback isolation: refreshing an API token must never tear down a playing stream. Playback receives an immutable header snapshot.
- Graceful failure: a wrong endpoint, HTML captive page, expired token, malformed JSON, or unsupported codec degrades into a readable error and, where possible, an alternate endpoint or engine.

Non-goals: VOD/series, catch-up playback, recording, DRM, torrents, and bundling any portal.

## 2. System diagram

    ┌──────────────────────────────────────────────────────────────────────┐
    │                          SwiftUI layer                               │
    │  ContentView ─ PlayerPane ─ PortalManagerView ─ PortalEditorView     │
    │       │              │                                               │
    │       ▼              ▼                                               │
    │  AppState  ◄──── PortalStore                                         │
    │   (@MainActor)       │                                               │
    │       │              ├──────────► Core Data (profiles)               │
    │       │              └──────────► Keychain (passwords, tokens)       │
    │       │                                                              │
    │       ├──────────────► PlayerCoordinator (@MainActor)                │
    │       │                     │                                        │
    │       │                     ├── AVPlayerEngine ── AVPlayerLayer      │
    │       │                     └── VLCPlaybackEngine (optional)         │
    │       ▼                                                              │
    │  StalkerClient (actor)                                               │
    │       ├── endpoint discovery / handshake / get_profile               │
    │       ├── cookie jar / token refresh single-flight                   │
    │       ├── live: genres / ordered list / EPG / create_link            │
    │       ├── VOD: categories / ordered list / seasons / episodes        │
    │       │        / create_link / get_episode_stream                    │
    │       └── StalkerHTTPTransport ──► URLSession (ephemeral)            │
    └──────────────────────────────────────────────────────────────────────┘

Module split:

- StalkerDeskCore — models, persistence, Keychain, networking, playback. Testable and UI-independent.
- StalkerDesk — app entry, state orchestration, SwiftUI views.
- StalkerDeskChecks — headless protocol checks using an in-process mock portal.

## 3. Runtime flows

### 3.1 Portal connection and authentication

    AppState.connect(profile)
      │
      ├─ StalkerClient.connect(profile, credentials)
      │    │
      │    ├─ PortalURLResolver.candidates(profile.portalURL)
      │    │
      │    ├─ Try cached Keychain session (fresh < 50 min, endpoint still valid)
      │    │     └─ get_profile → success? return session
      │    │
      │    └─ For each endpoint candidate:
      │         1. handshake (token empty)         GET ?type=stb&action=handshake&token=
      │         2. if no token: challenge retry     token=<random>&prehash=<sha1(token)>
      │         3. store token + Set-Cookie
      │         4. optional do_auth (if username is configured)
      │         5. get_profile (device_id, signature, metrics, hw_version…)
      │         6. persist session to Keychain, return PortalSession
      │
      ├─ connectionState = .connected
      ├─ mark profile lastConnectedAt
      └─ fetchGenres → show categories (no automatic all-channel burst)

For a bare-host portal URL, the client first fetches the portal landing page with URLSession redirect following. The final URL (for example /stalker_portal/c/) and any Set-Cookie headers are used to prioritize the real API endpoint (for example /stalker_portal/server/load.php) and carry Cloudflare/PHP cookies into the handshake. This avoids probing multiple dead endpoints and tripping portal rate limits. Endpoint probing then continues after non-auth failures. A portal may answer 404/HTML on /server/load.php but work at /c/portal.php or /stalker_portal/server/load.php. Authentication failures are remembered and surfaced if no candidate works.

### 3.2 Channel playback

    selectChannel(channel)
      ├─ cancel previous resolve/EPG tasks
      ├─ STOP current player (avoid stale video under a new title)
      ├─ fetchEPG(channel.id) in parallel
      └─ resolveStream(channel)
           ├─ create_link (cmd = channel.cmd)
           ├─ parse js.cmd / js (ffmpeg prefix, percent encoding)
           ├─ rewrite localhost → portal endpoint host
           ├─ build stream headers (UA, Referer, Origin, Cookie, Bearer)
           └─ PlayerCoordinator.play(PlaybackRequest)

    PlayerCoordinator
      ├─ choose engine (Automatic / AVPlayer / VLCKit)
      ├─ attach engine NSView into the SwiftUI surface
      ├─ inject headers via AVURLAssetHTTPHeaderFieldsKey (AVPlayer)
      └─ observe item status, time control, stalls, end, PiP

### 3.3 Token refresh

    requestJSON(authenticated: true)
      ├─ ensureTokenValid(): local age ≥ 55 min? refresh
      ├─ send request with Cookie + Authorization
      ├─ HTTP 401/403 or {"error":"Authorization failed"}?
      │    ├─ refreshSession() (single-flight Task)
      │    │    ├─ handshake
      │    │    ├─ do_auth if configured
      │    │    ├─ get_profile
      │    │    └─ persist new token/cookies
      │    └─ retry original request once
      └─ still failing → StalkerError.sessionExpired

The refreshInFlight Task and isRefreshing flag prevent recursion: get_profile executed inside a refresh can never start a nested refresh.

## 4. Data models

All models crossing actor/UI boundaries are immutable Sendable value types. NSManagedObject never escapes the persistence layer.

### 4.1 Domain models

| Type | File | Key fields |
| --- | --- | --- |
| MACAddress | PortalModel.swift | 6 octets, canonical formatting, cookie encoding, MAG OUI check |
| DeviceIdentity | PortalModel.swift | serial (MD5[:13]), device ID (SHA-256), device_id2, signature, hw_version_2, metrics JSON |
| PortalProfile | PortalModel.swift | UUID, name, URL, MAC, device ID, serial, timezone, username, default flag, timestamps |
| PortalDraft | PortalModel.swift | editable form state + validation; random MAC/identity generation |
| PortalCredentials | PortalModel.swift | optional username/password (password lives in the Keychain) |
| StalkerContentMode | IPTVModels.swift | live / movies / series UI mode |
| StalkerMediaItem | IPTVModels.swift | VOD movie, series, season or episode metadata (poster, ids, cmd, duration) |
| StalkerGenre | IPTVModels.swift | id, title, alias, censored, synthetic "All Channels" |
| StalkerChannel | IPTVModels.swift | id, name, number, cmd, logo URL, genre, xmltv id, HD/archive/censored flags |
| StalkerEPGProgram | IPTVModels.swift | channel id, title, description, start/end, category, archive/recording flags |
| StalkerUserProfile | IPTVModels.swift | account name, status, expiry, timezone, play token, subscription heuristic |
| PortalSession | IPTVModels.swift | portal id, resolved endpoint, token, cookies, account, issue time |
| ResolvedStream | IPTVModels.swift | channel id, stream URL, HTTP headers, raw create_link command |
| PlaybackRequest | IPTVModels.swift | URL, headers, title/subtitle, channel id, live flag, engine preference |
| PlaybackState | PlayerCoordinator.swift | idle/preparing/buffering/playing/paused/failed/ended |
| PlayerAspectRatio | PlayerCoordinator.swift | 16:9 / fit / zoom |

### 4.2 Core Data schema

Entity: PortalProfileEntity (programmatic model in PersistenceController.swift).

| Attribute | Type | Notes |
| --- | --- | --- |
| id | UUID | stable key |
| name | String | display name |
| portalURL | String | normalized portal URL |
| macAddress | String | canonical AA:BB:CC:DD:EE:FF |
| deviceID | String | generated or user override |
| serialNumber | String | generated or user override |
| timezone | String | IANA identifier, sent in cookie |
| username | String? | optional account login |
| isDefault | Bool | one preferred portal |
| sortIndex | Int64 | stable manual ordering |
| createdAt | Date | creation |
| lastConnectedAt | Date? | updated after successful auth |

Why Core Data rather than SwiftData: SwiftData is macOS 14+, while this app targets Ventura (macOS 13). The model is defined in code to avoid a separate .xcdatamodeld resource. The persistent store lives at ~/Library/Application Support/StalkerDesk/StalkerDesk.sqlite; persistent history tracking is enabled.

### 4.3 Keychain items

| Service | Account | Value |
| --- | --- | --- |
| com.stalkerdesk.portal-password | portal UUID | password UTF-8 |
| com.stalkerdesk.stalker-session | portal UUID | JSON CachedStalkerSession (endpoint, token, cookies, issuedAt) |

Accessibility is kSecAttrAccessibleAfterFirstUnlock. Session cache is only restored if under 50 minutes old and its endpoint is still among the resolved candidates. Passwords are only sent if a username exists.

### 4.4 Parsing strategy

Stalker responses are legacy PHP JSON with unstable shapes:

- js can be an object, an array, a string, false, or absent.
- Identifiers are sometimes numbers, sometimes strings.
- get_epg_info can return channel-keyed objects or arrays.
- Some portals emit trailing commas, BOMs, anti-XSSI prefixes, or raw control characters.

StalkerJSONParser first normalizes the body (BOM, anti-XSSI prefix, trailing commas, raw control chars), then decodes into JSONValue. StalkerPayloadParser maps fields with fallback key names and type coercion. An HTML response is detected early and reported as a wrong endpoint rather than a decoding failure.

## 5. Networking and protocol details

### 5.1 Endpoint resolution

PortalURLResolver builds candidates in priority order:

- Explicit .../load.php or .../portal.php → use as-is.
- .../c/ → /server/load.php, /stalker_portal/server/load.php, /c/portal.php, /c/server/load.php, /portal.php.
- .../stalker_portal/ → /stalker_portal/server/load.php, /server/load.php, /stalker_portal/portal.php.
- Generic host/path → appends conventional server/load.php, stalker_portal/server/load.php, portal.php, c/portal.php.

For bare hosts, the landing-page redirect supplies the preferred candidate list before probing. The first candidate returning a usable handshake token wins. The resolved endpoint is cached in memory and in the Keychain session snapshot.

### 5.2 Device headers

Every API request sends:

| Header | Value |
| --- | --- |
| User-Agent | Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 safari/533.3 |
| X-User-Agent | Model: MAG250; Link: WiFi |
| Cookie | mac=<percent-encoded MAC>; stb_lang=en; timezone=<encoded>; token=<token>; <server cookies> |
| Authorization | Bearer <token> on authenticated calls |
| Referer | best-effort /c/ referer derived from the resolved endpoint |
| Accept / Accept-Language / Pragma / Cache-Control | compatibility values |

Every request appends JsHttpRequest=1-xml. URLSession is configured ephemeral with its own cookie storage disabled; cookies are captured from Set-Cookie and replayed explicitly. This makes cookie state portal-specific and avoids contamination between profiles.

### 5.3 Handshake and profile

Handshake query:

    ?type=stb&action=handshake&token=&JsHttpRequest=1-xml

If no token is returned, a challenge retry is sent:

    ?type=stb&action=handshake&token=<32-char random>&prehash=<sha1(token)>&JsHttpRequest=1-xml

The token is extracted from js.token, a top-level token, or a token-like js string. get_profile sends:

- stb_type=MAG250, client_type=STB, hd=1, num_banks=2, video_out=hdmi
- sn, device_id, device_id2, signature, metrics, hw_version_2, timestamp
- Image/API version strings expected by Ministra portals.

When a username is configured, do_auth is attempted between handshake and profile. A failure is surfaced as an authentication error. get_profile must contain at least an id, name, login or mac; an empty js object is treated as an unauthorized device. This prevents a false "Connected" state in which handshake succeeds but every subsequent call returns Authorization failed.

Device identity is derived deterministically from the MAC unless the user supplies custom values. Changing the MAC in the editor regenerates only identities that still match the previous MAC's derived defaults; custom provider values are preserved. If an older profile passes handshake but returns an empty profile, AppState repairs an app-generated stale identity once and reconnects.

### 5.4 API mapping

| Feature | Type/action | Extra parameters |
| --- | --- | --- |
| Genres | type=itv&action=get_genres | — |
| Channel page | type=itv&action=get_ordered_list | genre, p, fav=0, sortby=number |
| Live EPG | type=itv&action=get_epg_info | period=<hours> |
| Short EPG fallback | type=itv&action=get_short_epg | ch_id, size=12 |
| Stream URL | type=itv&action=create_link | cmd=<channel.cmd>, series/storage/ad flags, fav=0 |
| VOD categories | type=vod&action=get_categories | — |
| VOD/movie/series list | type=vod&action=get_ordered_list | category, p, sortby=added |
| Seasons | type=vod&action=get_ordered_list | movie_id, season_id=0, episode_id=0 |
| Episodes | type=vod&action=get_ordered_list | movie_id, season_id, episode_id=0 |
| Movie stream | type=vod&action=create_link | cmd; legacy /media/file_<id>.mpg fallback |
| Episode stream | type=vod&action=get_episode_stream | episode_id; falls back to ordered list + create_link |
| Profile | type=stb&action=get_profile | device identity + metrics |
| Account auth | type=stb&action=do_auth | login, password, device ids |

get_ordered_list is paged. The client reads total_items and max_page_items, fetches remaining pages in batches of 3 (configurable), caps at 60 pages, and de-duplicates by channel id. Search is local.

### 5.5 EPG

The client requests 6 hours of bulk guide data with get_epg_info, parses both possible shapes:

- js.data keyed by channel id → [program]
- js.data array where each item has ch_id

It filters to the current channel, sorts by start time, and caches per channel for 5 minutes. If the channel has no programs, it falls back to get_short_epg with size=12. Programs use start_timestamp/stop_timestamp when present, otherwise parse time/time_to strings in the portal timezone. The UI shows a live progress card and the next eight programs.

### 5.6 VOD and series resolution

VOD categories are fetched with type=vod&action=get_categories and mapped with the same category parser used for live genres. Movies and series share those categories; items are split by is_series. Pagination uses the same total_items/max_page_items logic.

Series detail:

1. get_ordered_list with movie_id=<series id>&season_id=0&episode_id=0 returns seasons.
2. get_ordered_list with movie_id and the selected season_id returns episodes.
3. Episode playback first tries the item's cmd, then get_episode_stream, then a legacy fallback: fetch the stream record with get_ordered_list, then create_link with /media/file_<id>.mpg.
4. Stream headers (MAG UA, Referer, Cookie, Bearer) are injected exactly as for live streams. Relative /media/... URLs are resolved against the portal origin.

### 5.7 Stream URL resolution

create_link returns either a string js or an object with cmd/url. StreamCommandParser:

1. Trims and percent-decodes the command.
2. Strips ffmpeg, auto, proxy prefixes and quotes.
3. Parses an HTTP(S) URL.
4. Rewrites localhost/127.0.0.1 to the portal endpoint host, inheriting the portal port only when the stream used a default port.
5. Returns ResolvedStream with headers:
   - MAG User-Agent and X-User-Agent
   - Referer: <portal>/c/
   - Origin: <portal>
   - Cookie containing MAC, timezone, token, and server cookies
   - Authorization: Bearer <token>

The raw command may contain an embedded token; it is preserved as part of the URL.

## 6. Persistence and state orchestration

- PortalStore (@MainActor) owns the Core Data stack lifecycle, maps entities to PortalProfile, saves Keychain passwords, and publishes profiles.
- AppState (@MainActor) owns the active portal, content mode (Live/Movies/Series), StalkerClient, catalog, EPG, media detail state, errors, and PlayerCoordinator. It does not auto-fetch "All Channels" after login; categories appear first and a category is fetched only when selected, avoiding a burst of paginated requests. VOD categories are cached per connected session so switching between Movies and Series does not repeat the category request.
- StalkerClient is an actor; its state is serialized. Network waits may suspend the actor, but actor isolation ensures single token/cookie state.
- PlayerCoordinator and both playback engines are @MainActor because AVKit/AppKit rendering must stay on the main thread.
- A per-connection UUID plus task cancellation prevents stale async results from overwriting a newer portal/channel selection.
- On portal switch, the old client is disconnected in a detached task; the UI resets immediately.

## 7. Playback architecture

    PlayerCoordinator
      ├─ PlaybackEngine protocol (load/play/pause/stop/seek/volume/aspect/PiP)
      ├─ AVPlayerEngine
      │    ├─ AVPlayer + AVPlayerLayer hosted in NSView
      │    ├─ HTTP header dictionary passed to AVURLAsset
      │    ├─ KVO for item.status, timeControlStatus, isPlaybackLikelyToKeepUp
      │    ├─ notifications for end/stall
      │    ├─ periodic time observer → UI
      │    └─ AVPictureInPictureController
      └─ VLCPlaybackEngine (conditional)
           ├─ VLCMediaPlayer + NSView drawable
           ├─ libVLC :http-user-agent, :http-referrer, :http-cookie options
           └─ state/time delegate → UI

Header injection. AVFoundation has no public per-asset header API; the implementation uses the widely deployed AVURLAssetHTTPHeaderFieldsKey option. This is technically undocumented, so a hardened App Store build may choose to replace it with an AVAssetResourceLoader or a local reverse proxy. The code isolates this in AVPlayerEngine.load.

Fallback. Automatic mode prefers AVPlayer for HLS/MP4 and VLCKit for raw TS when VLCKit is available. If AVPlayer fails to open the asset, the coordinator retries once with VLCKit, shows a fallback notice, and forwards the same immutable header set. Without VLCKit, failures remain visible with a retry button.

PiP, fullscreen, aspect. PiP uses AVPictureInPictureController(playerLayer:) and is only offered by AVPlayer. Fullscreen is presented by FullscreenWindowController as a dedicated borderless, screen-covering NSWindow hosting FullscreenPlayerView. This avoids AppKit's native-fullscreen state machine, which can oscillate when SwiftUI player surfaces are re-parented. PlayerCoordinator exposes onToggleFullscreen, keeps a weak reference to the primary browse surface, and restores it when the fullscreen window closes. AppState mirrors player.isFullScreen so in-page player surfaces deactivate while the dedicated window owns the engine view. Escape, F and the explicit Exit Fullscreen button close the window. Aspect modes are implemented in VideoSurfaceView.layout(): 16:9 letterbox, fit (resizeAspect), zoom (resizeAspectFill). VLCKit renderer modes are left to libVLC.

UI shell. ContentView is a ten-foot Apple TV-style shell: dark cinematic background, large top tabs for Live TV / Movies / Web Series, a horizontal category rail, adaptive channel/poster shelves, and a full-width detail/player stage. TVTheme centralizes colors, spacing, card styling and hover affordances. The browse/detail structure and cards use cross-platform SwiftUI so they can be reused by a future tvOS target; only the player surface and fullscreen window are macOS-specific today.

Keyboard. A local NSEvent monitor maps ↑/↓ to channel switching, space to play/pause, F to fullscreen, P to PiP, M to mute, and arrows left/right to seek. When a text field is first responder, events are ignored. The shortcuts are also exposed as menu commands.

## 8. Resilience and cancellation

| Condition | Behavior |
| --- | --- |
| DNS/timeout/connection loss | Retry GET with 250–750 ms backoff (3 attempts total) |
| HTTP 5xx | Retry, then surface httpStatus |
| HTTP 404 / HTML response | Treat endpoint as wrong, continue candidate probing |
| HTTP 429 | Stop immediately with a rate-limit message; no extra candidate probing |
| HTTP 401/403 | Refresh token once, retry once, then sessionExpired |
| js=false on auth flows | unauthorized with portal error text |
| Malformed JSON | Lenient normalization, then typed invalidJSON |
| Cached session rejected | Clear cache, perform fresh handshake |
| Stale derived device identity | Auto-repair once when get_profile is empty/unauthorized, then reconnect |
| Empty get_profile object | Treated as unauthorized instead of false success |
| Genre HTTP 429 | Automatic 8s/18s retries, then visible Retry Categories action |
| Stream failure | VLCKit fallback when linked and not already attempted |
| User switches portal/channel | Cancel tasks; generation guard drops late results |
| App closes | Stop keyboard monitor, stop engine, disconnect client |

## 9. Security and privacy

- No analytics, telemetry, accounts, or third-party services.
- Secrets: Keychain only. HTTP headers/cookies are never logged; log statements redact identifiers and omit token values. PlaybackRequest.diagnosticURL drops query strings before diagnostics.
- App Transport Security: NSAllowsArbitraryLoads is enabled because many Stalker portals are HTTP-only. Prefer HTTPS portals. If shipping to the Mac App Store, expect to justify this exception and supply the App Sandbox entitlements.
- Passwords over HTTP are flagged in the UI. The app does not silently downgrade a portal URL.
- Only connect to services you are authorized to use. The client implements no DRM bypass and ships no content.

## 10. Testing

swift run StalkerDeskChecks executes:

- MAC validation, normalization and cookie encoding.
- Portal URL candidate generation for /c/, nested and explicit endpoints.
- Stream command parsing (ffmpeg prefix, percent encoding, localhost rewrite, invalid input).
- Lenient JSON handling.
- Full mocked handshake → profile → genres → 2-page channel list → EPG → create_link flow, asserting headers, cookies and URL rewriting.
- Mocked VOD categories → 2-item movie/series catalog → poster mapping → movie create_link → seasons → episodes → episode stream resolution.
- Endpoint fallback to /c/portal.php.
- Root-host candidate generation, ensuring every candidate keeps the original host.
- 401 single-flight token refresh, asserting the retried request uses token #2.
- Optional live portal diagnostic via STALKERDESK_LIVE_CHECK.

The mock portal is an actor implementing StalkerHTTPTransport, so checks are deterministic and never touch the network.

## 11. Extension points

- Portal-specific signatures / CSRF: add a signer inside StalkerClient.performRequest or a decorator transport. The current get_profile already emits device signature fields.
- VOD extensions: favorites/recent entities, embedded series[] support, and a 7-day EPG grid.
- Catch-up: EPG programs already carry archive flags and timestamps; add a create_link variant with archive parameters.
- Alternative player: implement PlaybackEngine and register it in PlayerCoordinator.startEngine.
- Local reverse proxy: if the AVFoundation header key is unacceptable, route ResolvedStream through a loopback HTTP proxy and play from 127.0.0.1; the engine interface stays unchanged.
- Settings: move timeout/token/engine preferences to a Settings scene and pass a StalkerClientConfiguration into AppState.

## 12. Known limitations

- Portal variants matter. Some deployments require additional signing headers, X-STB-* values, or account-specific device identity. Those can be added without restructuring the client.
- Raw MPEG-TS and MPEG-2 playback on macOS requires VLCKit; AVPlayer handles HLS/MP4 well but not arbitrary TS.
- PiP is AVPlayer-only. VLCKit rendering with a custom vout could add it later.
- EPG is live-only and fetches a 6-hour window; no 7-day grid or catch-up UI.
- VOD support is best-effort across Stalker variants: portals using nonstandard season/episode shapes or extra signing may need parser additions.
- Only one portal is connected at a time.
- AVFoundation header injection relies on an undocumented key.
- There is no in-app browser, no HTTP proxy, no certificate pinning, and no self-signed TLS override.
- The ad-hoc developer bundle is unsandboxed. Distribution should enable the App Sandbox and network-client entitlement in Resources/StalkerDesk.entitlements.

## 13. Build and packaging

Package.swift defines the app, core library, and checks executable. scripts/build-app.sh:

1. Builds StalkerDesk in debug or release.
2. Creates StalkerDesk.app/Contents/{MacOS,Resources}.
3. Copies the binary, Info.plist and optional AppIcon.icns.
4. Ad-hoc signs unless CODESIGN_IDENTITY is set.

The app uses NSApplication, opens a single window, activates on launch, and terminates when the last window closes.

## 14. File map

    Sources/
    ├── StalkerDeskCore/
    │   ├── Models/
    │   │   ├── PortalModel.swift          # profile, MAC, device identity, URL resolver
    │   │   ├── IPTVModels.swift           # genres/channels/EPG/session/streams
    │   │   ├── PersistenceController.swift
    │   │   └── KeychainStore.swift
    │   ├── Networking/
    │   │   ├── StalkerClient.swift        # actor, handshake, auth, HTTP, refresh
    │   │   ├── StalkerClient+API.swift    # genres/channels/EPG/create_link
    │   │   ├── StalkerPayloadParser.swift
    │   │   ├── StalkerHTTPTransport.swift
    │   │   └── JSONValue.swift
    │   └── Playback/
    │       ├── PlayerCoordinator.swift
    │       ├── AVPlayerEngine.swift
    │       └── VLCPlaybackEngine.swift
    ├── StalkerDesk/
    │   ├── StalkerDeskApp.swift
    │   ├── AppState.swift
    │   ├── PortalStore.swift
    │   ├── AppLog.swift
    │   ├── TVTheme.swift
    │   ├── FullscreenWindowController.swift
    │   └── Views/
    │       ├── ContentView.swift
    │       ├── PlayerPane.swift
    │       ├── PlayerSurface.swift
    │       ├── MediaCatalog.swift
    │       ├── PortalEditorView.swift
    │       └── PortalManagerView.swift
    └── StalkerDeskChecks/
        └── main.swift

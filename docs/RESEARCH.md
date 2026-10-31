# Research: native YouTube players on the Mac

What exists today, how each app handles playback and media keys, and what Encore borrows.

## The problem

Safari publishes Now Playing information for a tab only while that tab is an active media session. After a pause, especially with Safari in the background, macOS may route the ⏯ key elsewhere: to Music.app or to nothing at all. A dedicated app that keeps its session registered while paused avoids this.

## Apps studied

### Kaset (sozercan/kaset), Swift/SwiftUI, MIT
The most thoughtful native client, though it covers YouTube Music only and needs macOS 26+.
- **Singleton playback web view.** `SingletonPlayerWebView.shared` is created once and stays mounted. In the hidden state it is 1×1 with opacity 0. This avoids duplicate audio streams and survives view recreation.
- **Window lifecycle.** `windowShouldClose` calls `orderOut` and returns `false`, and `applicationShouldTerminateAfterLastWindowClosed` returns `false`. The music keeps playing after the window closes and stops on quit.
- **Media keys.** `MPRemoteCommandCenter` handlers route to the active player. A document-start script wraps `navigator.mediaSession.setActionHandler`, so the page cannot take over seek keys.
- **JS bridge.** It uses a single `WKScriptMessageHandler` with `STATE_UPDATE` and `TRACK_ENDED` messages. Progress comes from the `<video>` element, and stale updates are rejected by video id.
- **Pitfalls it documents:**
  - Hidden views can auto-resume server-side playback on launch, so autoplay is blocked during preload.
  - Per-tick progress updates cause SwiftUI churn, so progress should be read only in leaf views.
  - Repeated full loads pile up history.
- **User agent.** A static Safari UA string avoids "browser not supported" pages.
- **Audio.** Its equaliser uses a Core Audio process tap on WebKit's GPU process. That needs the screen and system audio recording permission.

### Pear Desktop (formerly th-ch/youtube-music), Electron
- It uses a plugin model: ad blocking, SponsorBlock, lyrics, shortcuts and media keys, Discord presence, and a visualiser.
- It shows how valuable small quality-of-life features are (ad skip, keyboard control, visualiser), though Electron costs memory and doesn't feel native.

### Clicker for YouTube (DBK Labs)
- It's a Mac-native shell around regular YouTube, with a Dock icon, picture-in-picture, a menu bar subscriptions list and an ad blocker.
- Users report breakage on newer macOS versions and an unresponsive developer.

### Smaller projects
- **youtube-music-macos** (0xjemm) is a lean WebKit wrapper with media keys and Control Center artwork.
- **menutube** is a SwiftBar plugin that plays audio through mpv and yt-dlp. mpv registers with `MPNowPlayingInfoCenter`, so media keys work.
- **SmartPause / Beamhook** are menu bar utilities that redirect media keys to the right app. They work around the same Safari problem.

### VoxelWall (visual inspiration)
- These are music-reactive live wallpapers for Mac, built as real-time 3D scenes: extruded voxel terrain, point-cloud "cloth" seas, warp tunnels, vortex storms and topographic contours.
- Encore's GPU scenes (Aurora, Silk, Orb, Tide) are original shaders. They take the idea of music-reactive scenes and aim for something calmer.

## What Encore takes and adds

| Idea | Source | Encore |
|---|---|---|
| Long-lived playback web view | Kaset | `PlayerEngine` plus `WebViewParking`: web views move between windows or park offscreen and never reload |
| Close-to-background | Kaset | The window closes, the player keeps running, and the menu bar and media keys stay live |
| Own the media session | Kaset, menutube | `MPRemoteCommandCenter` plus `MPNowPlayingInfoCenter` that stays paused instead of clearing, de-duplicated against WebKit's session |
| Safari UA | Kaset | The version suffix matches the running macOS |
| Visibility spoof | common wrappers | No throttling or "paused" dialogs while hidden; `inactiveSchedulingPolicy = .none` |
| Ad skip, still-watching | Pear | It clicks YouTube's own Skip button and confirm dialog |
| Visualiser | Pear, VoxelWall, Kaset (audio tap) | Eight calm styles fed by a Core Audio tap on Encore's own WebKit audio (Web Audio returns silence for YouTube in WebKit), with a gentle simulation as fallback |
| Mini player / PiP | Clicker | A floating panel that adopts the live player view |
| Two web views | new | Browsing never interrupts playback |
| Audio mode | new | The video is hidden while the stream stays at the highest quality for the best audio; a 144p data saver is optional |

## Visualiser research (round 2)

What separates premium visualisers from cheap ones:

- **Feedback trails (MilkDrop / Butterchurn).** Each frame is drawn into the next through a warp (zoom, rotation and sinusoidal displacement) with a decay of about 0.98, using `(prev - 0.002) * 0.99` style fading. Butterchurn uses ping-pong framebuffers, a 48×36 warp mesh and three blur levels. → Encore's feedback pass, used by **Flow** (add mode) and by **Swarm**, **Halo** and **Tide** (max mode, so trails don't lift the background).
- **Additive glow and particles that listen individually (Magnetosphere by Robert Hodgin).** Every particle is tied to its own FFT frequency. Particles orbit spinning orbs under attract, repel and rotational forces, and additive blending makes them glow. Version 2.0 runs millions of particles in GLSL, with orbs drawn in the shader and radiant bursts on beats. Hodgin notes that losing reliable beat detection made the iTunes port feel less responsive. → **Swarm**: 60,000 particles orbit three spinning cores, each particle driven by its own band, with Kepler-like speeds and beat bursts.
- **Album-art ambience (Apple Music).** Colours are sampled from the artwork, then the art is warped and heavily blurred into a moving mesh gradient. → **Ambient** samples the real artwork through domain-warped coordinates at low mip levels.
- **Film-style post-processing.** HDR rendering with a soft-knee bloom (dual-filter down/up chain), an ACES tonemap, a vignette, subtle chromatic aberration that spikes on beats, and grain or dither to avoid banding.
- **Audio mapping.** MilkDrop's `bass/mid/treb` values sit around 1.0 at the song's recent average, with attenuated `_att` variants. → Encore's band levels are relative to a 3-second average. Beats come from spectral flux on the low bands with an adaptive threshold (1.7 × running mean + 0.04, at most one beat every 220 ms), and fast-attack, slow-release easing.

Sources: geisswerks.com MilkDrop preset authoring guide; github.com/jberg/butterchurn (renderer.js, visualizer.js); roberthodgin.com (Magnetosphere, Magnetosphere 2.0, Dust); synesthesia.live.

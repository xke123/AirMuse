# AirMuse macOS – Windows Source Code Audit
> Generated: 2026-11-21 | Auditor: architect (swarm)

## 1. Repository Layout

```
AirMuse/
├── airplay/                  # Reverse-engineered AirPlay binary (older codebase)
│   ├── src/                  # C++ header-only analysis
│   └── docs/                 # Reverse engineering reports
├── AirMuse_Remastered/       # Modern Win32 C++ rewrite
│   └── src/
│       ├── core/             # Models, PlaybackStore, AppController
│       ├── lyrics/           # LyricsEngine
│       ├── media/            # Provider abstraction + adapters
│       │   └── provider/     # AppleMusic, Spotify, QQMusic adapters
│       └── ui/               # Win32 windows, GDI+ renderer, DockManager
└── AirMuse_macOS/            # (new) Swift SPM project
```

---

## 2. Module Responsibility Map

### 2.1 `airplay/` – Reverse-Engineering Reference

| File | Responsibility |
|---|---|
| `AirPlayTypes.hpp` | Window class names, WM_USER message IDs, playback command enums, button indices, geometry constants |
| `AirPlayAudioEngine.hpp/.cpp` | TAK lossless decoder DLL binding, DirectSound playback, seek/position |
| `AirPlayMainWindow.hpp/.cpp` | Main window (normal + mini mode), GDI+ glass renderer, snap-to-taskbar |
| `AirPlayMiniPlayer.hpp/.cpp` | 40px mini-bar, 16px button sprite sheet, hover-expand |
| `AirPlayGlassRenderer.hpp/.cpp` | Bitmap slicing (5px border, 20px caps), layered window compositing |

**Key geometry constants (extracted from binary):**
- Glass border thickness: 5 px  
- Glass cap height: 20 px  
- Mini-bar height: 40 px  
- Mini button size: 16×16 px  
- Corner radius: 4 px  
- Time font char width: 6 px, height: 7 px

### 2.2 `AirMuse_Remastered/src/core/`

| File | Responsibility |
|---|---|
| `Models.hpp` | `NowPlayingState`, `LyricLine`, `LyricsSnapshot`, `MediaCapabilities`, `DockSide`, `WebPlatform` enums |
| `PlaybackStore.hpp` | Mutex-guarded in-process store (get/set NowPlayingState + LyricsSnapshot) |
| `AppController.hpp/.cpp` | Top-level orchestrator: wires providers → store → UI windows |
| `WinCommon.hpp` | Windows.h precompiled header inclusion |

### 2.3 `AirMuse_Remastered/src/lyrics/`

| File | Responsibility |
|---|---|
| `LyricsEngine.hpp/.cpp` | Async worker thread, LRC parsing, timing offset, in-memory cache (trackKey → lines) |

### 2.4 `AirMuse_Remastered/src/media/`

| File | Responsibility |
|---|---|
| `IMediaSourceProvider.hpp` | Abstract provider interface (Id, Priority, IsAvailable, GetState, transport controls) |
| `MediaArbitrator.hpp/.cpp` | Priority-ranked provider selection, 500 ms polling loop |
| `SmtcProvider.hpp/.cpp` | Windows Media Transport Controls (SMTC) WASAPI session reader |
| `WebSourceProvider.hpp/.cpp` | WebView2-hosted web player bridge (JS ↔ C++ bridge) |
| `WebAdapters.hpp` | Adapter registry |
| `provider/IWebAdapter.hpp` | Web adapter interface (platform, URL, inject JS, control JS snippets) |
| `provider/AppleMusicAdapter.hpp` | Apple Music web adapter – MusicKit.js interop |
| `provider/QQMusicAdapter.hpp` | QQ Music web adapter |
| `provider/SpotifyAdapter.hpp` | Spotify web adapter |
| `airmuse_apple_engine.js` | 100 KB Apple Music JS engine (MusicKit event bridge) |
| `airmuse_ui_core.js` | 60 KB shared UI utilities |
| `apple_music_provider.js` | 38 KB provider-specific bridge |

### 2.5 `AirMuse_Remastered/src/ui/`

| File | Responsibility |
|---|---|
| `MainWindow.hpp/.cpp` | Main 3-panel window (glass renderer, docking, intro sequence) |
| `LyricsWindow.hpp/.cpp` | Floating lyrics overlay (always-on-top, scroll animation) |
| `LibraryWindow.hpp/.cpp` | Library browser (WebView2 host) |
| `DockManager.hpp/.cpp` | Multi-window snapping and layout management |
| `GlassRenderer.hpp/.cpp` | GDI+ bitmap compositing, glass slice tiling, layered window alpha |
| `GlassAssets.inl` | Embedded PNG assets as C arrays |
| `MotionCoordinator.hpp/.cpp` | Coordinates cross-window animations |
| `SpringAnimator.hpp` | Physics-based spring animation (stiffness, damping, velocity) |
| `UIElement.hpp` | Base UI element with hit-testing |

---

## 3. Logic Portable to macOS (High Confidence)

| Windows Concept | macOS Equivalent | Notes |
|---|---|---|
| `NowPlayingState` | `PlaybackState` (Domain) | Direct translation; replace `ULONGLONG` tick with `Date` |
| `LyricLine` / `LyricsSnapshot` | `LyricsLine` / `LyricsDocument` | Same structure |
| `MediaCapabilities` | `MusicProviderCapabilities` | Expanded for catalog/library ops |
| `IMediaSourceProvider` | `MusicPlaybackProvider` protocol | Async/await instead of polling thread |
| `MediaArbitrator` polling | `PlaybackCoordinator` actor | Actor-isolated, structured concurrency |
| `LyricsEngine` | `LyricsEngine` actor | Async fetch, offset, cache |
| `PlaybackStore` (mutex) | `PlaybackStore` actor | Actor replaces mutex |
| `SpringAnimator` | `CASpringAnimation` | Native macOS spring physics |
| `PlayerWindowMode` (Normal/Mini) | `PlayerMode` enum | Same semantics |
| Geometry constants | `DesignTokens` | 40pt mini-bar, 5pt border, 20pt cap |
| `WebPlatform` enum | Provider enum | AppleMusic / Spotify / QQMusic |

---

## 4. Windows-Only Concepts (Cannot Port)

| Component | Reason |
|---|---|
| `SmtcProvider` | SMTC / WASAPI is Windows-only; use `MediaPlayer` / `NowPlayingInfoCenter` on macOS |
| `WebView2` host | Replace with `WKWebView` |
| Win32 `HWND` / `WM_*` | Replace with `NSWindow` / `NSNotification` |
| GDI+ layered windows | Replace with `NSVisualEffectView` / `CALayer` |
| `tak_deco_lib.dll` | macOS uses `AVAudioEngine` / Core Audio |
| `SetProcessDpiAwarenessContext` | macOS handles HiDPI natively |
| `winrt::init_apartment` | No equivalent needed on macOS |

---

## 5. Technical Debt Identified

| Debt Item | Severity | Notes |
|---|---|---|
| Polling loop (500 ms) in `MediaArbitrator` | Medium | Replaced by async observation in `PlaybackCoordinator`; JS bridge still needs event-push rather than poll |
| JS injection scripts hardcoded as `wchar_t*` | Medium | Move to `.js` resource files with bundle loading |
| `airmuse_apple_engine.js` (100 KB) is monolithic | Low | Should be split into event-bridge + UI modules |
| `GlassAssets.inl` embeds PNG as C arrays | High | macOS: use Asset Catalog (xcassets) |
| Mutex in `PlaybackStore` without deadlock analysis | Medium | Replaced by actor; audit all lock sites |
| No unit tests in Windows codebase | High | macOS SPM project adds XCTest from day 1 |
| `WebSourceProvider` couples network I/O to UI thread | High | macOS: `WKWebView` is `@MainActor`, use message handlers |
| `LyricsEngine` uses detached `std::thread` | Medium | macOS: structured concurrency Task with cancellation |

---

## 6. Architecture Decision: Provider Strategy

The Windows version uses `WebView2`-based "web adapters" for Apple Music, Spotify, and QQ Music (injecting JS into the browser). On macOS this approach is **preserved** for Spotify and QQ Music but Apple Music gets a **native** provider path via `MusicKit` framework (available on macOS 12+), which eliminates the web bridge overhead for the primary use case.

Provider priority ladder:
1. **Native MusicKit** (Apple Music, macOS ≥ 12) – preferred
2. **WKWebView bridge** (Spotify, QQMusic) – fallback web adapter
3. **NowPlayingInfoCenter** (read-only SMTC equivalent) – last resort

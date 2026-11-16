# Migration record

## Audited source

AirMuse_4K_Remastered uses C++20/CMake, GDI+ layered windows, C++/WinRT SMTC, WinHTTP lyrics fetching,
and WebView2/MusicKit. Its main.cpp combines rendering, mouse input, timers, provider selection and lyrics
orchestration. SmtcController filters to Apple Music, WebLibraryPanel captures this in asynchronous WebView2
callbacks, and LyricsProvider starts a detached thread with a raw object pointer.

## Current implemented scope

The independent project has a compilable C++20 domain, provider/session interfaces, event bus, provider
manager, active-session arbiter, command coordinator, playback clock, cancellable lyrics pipeline, LRC
parser/matcher, mock provider, UI-state model, tween scheduler, minimal Win32 shell and unit tests.

## Deliberately pending

Apple Music WebView2 and Windows SMTC production adapters, actual HTTP/cache/artwork backends, configuration,
logging, GDI+ component extraction and the high-fidelity 4K UI have not yet been transferred. They are not
represented as fake integrations; provider contracts identify their next safe boundary.

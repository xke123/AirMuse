# Apple Music adapter contract

This adapter is intentionally not a reverse-engineered API client. Its production implementation will
migrate the existing WebView2 + MusicKit bridge using one media session and versioned JSON messages.
It must run on its owning STA dispatcher and invalidate callbacks with a shared lifetime token on shutdown.

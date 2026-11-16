# Architecture

Presentation depends on application, application depends on domain, and providers/services depend inward
on domain contracts. MediaSnapshot is the only media view-model crossing module boundaries. Every provider
emits typed MediaEvent values through a lifetime-bound subscription.

ProviderManager owns provider startup and shutdown. PlaybackCoordinator routes commands and PlaybackArbiter
chooses the visible session: locked session, then playing session, then preferred provider, then deterministic
freshest state. Snapshots are revision checked per provider/session.

PlaybackClock interpolates a calibrated position instead of waiting for constant updates. Lyrics requests use
std::jthread, stop_token, a generation guard and an identity cache, so stale results cannot replace a newer
track. Presentation consumes coordinator state only; its explicit view state and cancellable tween scheduler
keep animation and input separate from media business state.

Native window and WebView2 calls belong to the UI STA. Network/image work belongs to cancellable workers.
Providers must release callbacks before the host window or controller dies.

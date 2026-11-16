#pragma once
#include "core/application/PlaybackCoordinator.hpp"
#include "providers/mock/MockProvider.hpp"
namespace airmuse { class Application { public: Application(); ~Application(); Result<void> Start(); PlaybackCoordinator& Playback(){return coordinator_;} void TogglePlayback(); private: EventBus events_;ProviderManager providers_{events_};PlaybackCoordinator coordinator_{events_,providers_}; }; }

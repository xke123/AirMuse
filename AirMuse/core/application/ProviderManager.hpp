#pragma once
#include <memory>
#include <unordered_map>
#include "providers/interfaces/IMediaProvider.hpp"
namespace airmuse { class ProviderManager { public: explicit ProviderManager(EventBus&); Result<void> Register(std::shared_ptr<IMediaProvider>); void Shutdown(); std::shared_ptr<IMediaSession> FindSession(const ProviderId&,const SessionId&) const; private: EventBus& events_; std::unordered_map<ProviderId,std::shared_ptr<IMediaProvider>> providers_; std::vector<Subscription> subscriptions_; }; }

#pragma once
#include "core/application/PlaybackArbiter.hpp"
#include "core/application/ProviderManager.hpp"
namespace airmuse { enum class PlaybackCommand{Play,Pause,Next,Previous}; class PlaybackCoordinator { public: PlaybackCoordinator(EventBus&,ProviderManager&); Result<void> Dispatch(PlaybackCommand); Result<void> Seek(Milliseconds); std::optional<MediaSnapshot> Active()const{return arbiter_.Active();} void Prefer(std::optional<ProviderId> p){arbiter_.SetPreferredProvider(std::move(p));} void Lock(std::optional<SessionId>s){arbiter_.Lock(std::move(s));} private: ProviderManager& providers_; PlaybackArbiter arbiter_; Subscription subscription_; }; }

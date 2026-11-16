#pragma once
#include <memory>
#include <vector>
#include "core/domain/Result.hpp"
#include "core/events/EventBus.hpp"

namespace airmuse {
enum class ProviderStatus { Offline, Initializing, Ready, Failed };
class IMediaSession { public: virtual ~IMediaSession()=default; virtual SessionId Id() const=0; virtual MediaSnapshot GetSnapshot() const=0; virtual ProviderCapabilities GetCapabilities() const=0; virtual Result<void> Play()=0; virtual Result<void> Pause()=0; virtual Result<void> Next()=0; virtual Result<void> Previous()=0; virtual Result<void> SeekTo(Milliseconds)=0; };
class IMediaProvider { public: virtual ~IMediaProvider()=default; virtual ProviderId Id() const=0; virtual ProviderStatus GetStatus() const=0; virtual ProviderCapabilities GetCapabilities() const=0; virtual std::vector<std::shared_ptr<IMediaSession>> GetSessions() const=0; virtual Result<void> Initialize()=0; virtual void Shutdown()=0; virtual Subscription Subscribe(EventBus::Callback)=0; };
} // namespace airmuse

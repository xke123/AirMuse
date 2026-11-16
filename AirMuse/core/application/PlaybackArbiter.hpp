#pragma once
#include <optional>
#include <unordered_map>
#include "core/domain/MediaSnapshot.hpp"
namespace airmuse {
class PlaybackArbiter { public: void Observe(const MediaSnapshot&); void Remove(const ProviderId&,const SessionId&); void SetPreferredProvider(std::optional<ProviderId>); void Lock(std::optional<SessionId>); std::optional<MediaSnapshot> Active() const; private: std::unordered_map<std::string,MediaSnapshot> sessions_; std::optional<ProviderId> preferred_; std::optional<SessionId> locked_; };
} // namespace airmuse

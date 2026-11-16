#pragma once
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

namespace airmuse {
using Milliseconds = std::chrono::milliseconds;
using ProviderId = std::string;
using SessionId = std::string;
enum class PlaybackStatus { Unknown, Stopped, Paused, Playing, Buffering };
struct ProviderCapabilities { bool canPlay{}, canPause{}, canSkipNext{}, canSkipPrevious{}, canSeek{}; bool canReadPosition{}, canReadDuration{}, canReadArtwork{}, canReadLyrics{}, canControlVolume{}; };
struct MediaIdentity { std::string stableId; std::string normalizedTitle; std::string normalizedArtist; std::string artworkUri; bool operator==(const MediaIdentity&) const = default; };
struct Artwork { std::string uri; std::vector<std::uint8_t> bytes; };
struct MediaSnapshot {
    ProviderId providerId; SessionId sessionId; MediaIdentity identity;
    std::string title; std::string artist; std::string album; Artwork artwork;
    PlaybackStatus status{PlaybackStatus::Unknown}; Milliseconds position{}; Milliseconds duration{};
    double playbackRate{1.0}; ProviderCapabilities capabilities{}; std::uint64_t revision{};
    std::chrono::steady_clock::time_point updatedAt{std::chrono::steady_clock::now()};
};
inline bool IsNewer(const MediaSnapshot& candidate, const MediaSnapshot& current) {
    return candidate.providerId == current.providerId && candidate.sessionId == current.sessionId && candidate.revision >= current.revision;
}
} // namespace airmuse

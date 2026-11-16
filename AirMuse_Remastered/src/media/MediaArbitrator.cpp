#include "MediaArbitrator.hpp"

namespace airmuse {

void MediaArbitrator::RegisterProvider(std::shared_ptr<IMediaSourceProvider> provider) {
    if (provider) m_providers.push_back(std::move(provider));
}

std::shared_ptr<IMediaSourceProvider> MediaArbitrator::GetActiveProvider() const {
    std::shared_ptr<IMediaSourceProvider> bestProvider = nullptr;
    int bestScore = -1;

    for (auto const& p : m_providers) {
        if (!p || !p->IsAvailable()) continue;
        NowPlayingState st = p->GetState();
        if (st.title.empty() || st.title == L"AirMuse Ready") continue;

        int score = p->BasePriority() + (st.isPlaying ? 100 : 0);
        if (score > bestScore) {
            bestScore = score;
            bestProvider = p;
        }
    }
    return bestProvider;
}

NowPlayingState MediaArbitrator::ResolveBestState() const {
    if (auto active = GetActiveProvider()) return active->GetState();
    return NowPlayingState{};
}

} // namespace airmuse
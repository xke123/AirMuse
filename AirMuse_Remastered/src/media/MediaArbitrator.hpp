#pragma once
#include <vector>
#include <memory>
#include "IMediaSourceProvider.hpp"

namespace airmuse {

class MediaArbitrator {
public:
    void RegisterProvider(std::shared_ptr<IMediaSourceProvider> provider);
    std::shared_ptr<IMediaSourceProvider> GetActiveProvider() const;
    NowPlayingState ResolveBestState() const;

private:
    std::vector<std::shared_ptr<IMediaSourceProvider>> m_providers;
};

} // namespace airmuse
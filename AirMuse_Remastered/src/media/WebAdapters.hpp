#pragma once
#include "provider/IWebAdapter.hpp"
#include "provider/AppleMusicAdapter.hpp"
#include "provider/SpotifyAdapter.hpp"
#include "provider/QQMusicAdapter.hpp"

namespace airmuse {

/**
 * @brief 根据平台类型获取对应的 Web 适配器实例
 */
inline IWebAdapter* GetWebAdapter(WebPlatform platform) {
    static AppleMusicAdapter s_appleMusic;
    static SpotifyAdapter    s_spotify;
    static QQMusicAdapter    s_qqMusic;

    switch (platform) {
    case WebPlatform::Spotify:
        return &s_spotify;
    case WebPlatform::QQMusic:
        return &s_qqMusic;
    case WebPlatform::AppleMusic:
    default:
        return &s_appleMusic;
    }
}

/**
 * @brief 向后兼容辅助函数：获取平台规格参数
 */
inline WebAdapterSpec GetWebAdapterSpec(WebPlatform platform) {
    auto adapter = GetWebAdapter(platform);
    return adapter ? adapter->GetSpec() : WebAdapterSpec{};
}

} // namespace airmuse

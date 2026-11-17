#pragma once
#include "../../core/Models.hpp"

namespace airmuse {

struct WebAdapterSpec {
    WebPlatform platform;
    const wchar_t* name;
    const wchar_t* homeUrl;
    const wchar_t* injectScript;
    const wchar_t* playPauseJs;
    const wchar_t* nextJs;
    const wchar_t* prevJs;
    const wchar_t* seekJsTemplate;
};

// 抽象 Web 适配器接口：定义针对各 Web 音乐平台的接入规范与注入能力
class IWebAdapter {
public:
    virtual ~IWebAdapter() = default;

    virtual WebPlatform GetPlatform() const = 0;
    virtual const wchar_t* GetName() const = 0;
    virtual const wchar_t* GetHomeUrl() const = 0;
    virtual const wchar_t* GetInjectScript() const = 0;
    virtual const wchar_t* GetPlayPauseJs() const = 0;
    virtual const wchar_t* GetNextJs() const = 0;
    virtual const wchar_t* GetPrevJs() const = 0;
    virtual const wchar_t* GetSeekJsTemplate() const = 0;

    virtual WebAdapterSpec GetSpec() const {
        return {
            GetPlatform(),
            GetName(),
            GetHomeUrl(),
            GetInjectScript(),
            GetPlayPauseJs(),
            GetNextJs(),
            GetPrevJs(),
            GetSeekJsTemplate()
        };
    }
};

} // namespace airmuse

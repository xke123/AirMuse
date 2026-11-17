#pragma once
#include "IWebAdapter.hpp"
#include "../../resource.h"
#include <string>
#include <vector>
#include <fstream>
#include <windows.h>

namespace airmuse {

inline const wchar_t* GetAppleEngineScript() {
    static std::wstring s_cached;

    // 1. 优先尝试从外部文件读取 (支持本地开发即时热更)
    wchar_t exePath[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring exeDir = exePath;
    auto pos = exeDir.find_last_of(L"\\/");
    if (pos != std::wstring::npos) {
        exeDir = exeDir.substr(0, pos);
    }

    std::vector<std::wstring> paths = {
        exeDir + L"\\airmuse_apple_engine.js",
        exeDir + L"\\src\\media\\airmuse_apple_engine.js",
        exeDir + L"\\..\\src\\media\\airmuse_apple_engine.js",
        exeDir + L"\\..\\..\\src\\media\\airmuse_apple_engine.js",
        L"src/media/airmuse_apple_engine.js",
        L"../src/media/airmuse_apple_engine.js",
        L"../../src/media/airmuse_apple_engine.js",
        L"airmuse_apple_engine.js"
    };
    for (const auto& p : paths) {
        std::ifstream f(p, std::ios::binary);
        if (f.is_open()) {
            std::string utf8((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            if (!utf8.empty()) {
                int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
                if (len > 0) {
                    s_cached.resize(len);
                    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), &s_cached[0], len);
                    return s_cached.c_str();
                }
            }
        }
    }

    // 2. 若外部不存在脚本文件，自动回退使用打包内嵌在 EXE 中的原生资源
    if (s_cached.empty()) {
        HMODULE hMod = GetModuleHandleW(nullptr);
        HRSRC hRes = FindResourceW(hMod, MAKEINTRESOURCEW(IDR_JS_APPLE_ENGINE), RT_RCDATA);
        if (hRes) {
            HGLOBAL hMem = LoadResource(hMod, hRes);
            if (hMem) {
                const char* pData = static_cast<const char*>(LockResource(hMem));
                DWORD size = SizeofResource(hMod, hRes);
                if (pData && size > 0) {
                    int len = MultiByteToWideChar(CP_UTF8, 0, pData, static_cast<int>(size), nullptr, 0);
                    if (len > 0) {
                        s_cached.resize(len);
                        MultiByteToWideChar(CP_UTF8, 0, pData, static_cast<int>(size), &s_cached[0], len);
                    }
                }
            }
        }
    }
    return s_cached.c_str();
}

/**
 * @brief Apple Music Web 适配器 (现代 Amp-API + Image 3 渲染引擎)
 */
class AppleMusicAdapter : public IWebAdapter {
public:
    WebPlatform GetPlatform() const override { return WebPlatform::AppleMusic; }
    const wchar_t* GetName() const override { return L"Apple Music"; }
    const wchar_t* GetHomeUrl() const override { return L"https://music.apple.com"; }
    const wchar_t* GetInjectScript() const override { return GetAppleEngineScript(); }

    const wchar_t* GetPlayPauseJs() const override {
        return L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.isPlaying?mk.pause():mk.play();})();";
    }

    const wchar_t* GetNextJs() const override {
        return L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToNextItem();})();";
    }

    const wchar_t* GetPrevJs() const override {
        return L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToPreviousItem();})();";
    }

    const wchar_t* GetSeekJsTemplate() const override {
        return L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.seekToTime(%.3f);})();";
    }
};

} // namespace airmuse

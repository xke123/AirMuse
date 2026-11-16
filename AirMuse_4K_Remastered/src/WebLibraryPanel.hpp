#pragma once
#include <windows.h>
#include "SmtcController.hpp"

class WebLibraryPanel {
public:
    bool Initialize(HWND hostHwnd, HWND notifyHwnd = nullptr, UINT notifyMsg = 0);
    void Resize(int widthPx, int heightPx);
    void SetVisible(bool visible);
    void Shutdown();

    NowPlayingInfo GetNowPlayingSnapshot() const;
    void PlayPause();
    void Stop();
    void Next();
    void Previous();
    void SeekToPositionMs(int64_t targetMs);

private:
    HWND m_hostHwnd = nullptr;
    HWND m_notifyHwnd = nullptr;
    UINT m_notifyMsg = 0;
    struct Impl;
    Impl* m_impl = nullptr;
};

#pragma once
#include "../core/WinCommon.hpp"
#include "../core/Models.hpp"

namespace airmuse {

class DockManager {
public:
    void AttachWindows(HWND mainWnd, HWND lyricsWnd, HWND libraryWnd, HWND webHostWnd);
    void SetDpi(int dpi) { m_dpi = dpi; }

    bool IsSyncing() const { return m_syncing; }
    DockSide LyricsDockSide() const { return m_lyricsSide; }
    bool IsLibraryDocked() const { return m_libDocked; }

    void OnLyricsMoving(WINDOWPOS* wp);
    void OnLibraryMoving(WINDOWPOS* wp);

    void SyncAllDocked();
    void SyncWebHostBounds();

private:
    HWND m_main = nullptr;
    HWND m_lyrics = nullptr;
    HWND m_library = nullptr;
    HWND m_webHost = nullptr;
    int m_dpi = 96;
    bool m_syncing = false;
    DockSide m_lyricsSide = DockSide::Bottom;
    bool m_libDocked = true;
};

} // namespace airmuse

#pragma once
#include "../core/WinCommon.hpp"
#include "../core/Models.hpp"

namespace airmuse {

enum class RevealDir {
    FromLeft = 0,
    FromTop,
    FromBottom
};

class DockManager {
public:
    void AttachWindows(HWND mainWnd, HWND lyricsWnd, HWND libraryWnd, HWND webHostWnd);
    void SetDpi(int dpi) { m_dpi = dpi; }
    void SetMiniMode(bool mini) { m_miniMode = mini; }

    bool IsSyncing() const { return m_syncing; }
    DockSide LyricsDockSide() const { return m_lyricsSide; }
    bool IsLibraryDocked() const { return m_libDocked; }
    RevealDir LibraryRevealDir() const;

    void OnLyricsMoving(WINDOWPOS* wp);
    void OnLibraryMoving(WINDOWPOS* wp);

    void SyncAllDocked();
    void SyncWebHostBounds();

private:
    POINT ComputeLibraryDockPos(RECT const& rcMain, int libW, int libH, RevealDir* outDir = nullptr) const;

    HWND m_main = nullptr;
    HWND m_lyrics = nullptr;
    HWND m_library = nullptr;
    HWND m_webHost = nullptr;
    int m_dpi = 96;
    bool m_miniMode = false;
    bool m_syncing = false;
    DockSide m_lyricsSide = DockSide::Bottom;
    bool m_libDocked = true;
};

} // namespace airmuse
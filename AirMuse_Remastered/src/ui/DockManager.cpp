#include "DockManager.hpp"
#include "GlassRenderer.hpp"
#include <cmath>

namespace airmuse {

namespace {
constexpr int SNAP_DIST_PX     = 16;
constexpr int DOCK_OVERLAP_DIP = 2;
} // namespace

void DockManager::AttachWindows(HWND mainWnd, HWND lyricsWnd, HWND libraryWnd, HWND webHostWnd) {
    m_main = mainWnd;
    m_lyrics = lyricsWnd;
    m_library = libraryWnd;
    m_webHost = webHostWnd;
}

void DockManager::OnLyricsMoving(WINDOWPOS* wp) {
    if (m_syncing || !m_main || !m_lyrics || (wp->flags & SWP_NOMOVE)) return;
    RECT rcMain{}, rcLrc{};
    GetWindowRect(m_main, &rcMain);
    GetWindowRect(m_lyrics, &rcLrc);
    int lw = rcLrc.right - rcLrc.left;
    int lh = rcLrc.bottom - rcLrc.top;
    int snap = GlassRenderer::ToPx(SNAP_DIST_PX, m_dpi);
    int ov   = GlassRenderer::ToPx(DOCK_OVERLAP_DIP, m_dpi);

    struct Candidate { DockSide side; int x; int y; };
    Candidate cands[] = {
        { DockSide::Bottom, rcMain.left,           rcMain.bottom - ov },
        { DockSide::Top,    rcMain.left,           rcMain.top - lh + ov },
        { DockSide::Left,   rcMain.left - lw + ov, rcMain.top },
        { DockSide::Right,  rcMain.right - ov,     rcMain.top }
    };

    for (auto const& c : cands) {
        if (std::abs(wp->x - c.x) <= snap && std::abs(wp->y - c.y) <= snap) {
            wp->x = c.x;
            wp->y = c.y;
            m_lyricsSide = c.side;
            return;
        }
    }
    m_lyricsSide = DockSide::None;
}

void DockManager::OnLibraryMoving(WINDOWPOS* wp) {
    if (m_syncing || !m_main || !m_lyrics || (wp->flags & SWP_NOMOVE)) return;
    RECT rcMain{};
    GetWindowRect(m_main, &rcMain);
    int snap  = GlassRenderer::ToPx(SNAP_DIST_PX, m_dpi);
    int dockX = rcMain.right - GlassRenderer::ToPx(DOCK_OVERLAP_DIP, m_dpi);

    if (std::abs(wp->x - dockX) <= snap && std::abs(wp->y - rcMain.top) <= snap) {
        wp->x = dockX;
        wp->y = rcMain.top;
        m_libDocked = true;
    } else {
        m_libDocked = false;
    }
}

void DockManager::SyncAllDocked() {
    if (!m_main) return;
    RECT rcMain{};
    GetWindowRect(m_main, &rcMain);
    int ov = GlassRenderer::ToPx(DOCK_OVERLAP_DIP, m_dpi);

    m_syncing = true;
    if (m_lyrics && IsWindowVisible(m_lyrics) && m_lyricsSide != DockSide::None) {
        RECT rcLrc{};
        GetWindowRect(m_lyrics, &rcLrc);
        int lw = rcLrc.right - rcLrc.left;
        int lh = rcLrc.bottom - rcLrc.top;
        int x = rcMain.left, y = rcMain.bottom - ov;
        if (m_lyricsSide == DockSide::Top)   { x = rcMain.left; y = rcMain.top - lh + ov; }
        if (m_lyricsSide == DockSide::Left)  { x = rcMain.left - lw + ov; y = rcMain.top; }
        if (m_lyricsSide == DockSide::Right) { x = rcMain.right - ov; y = rcMain.top; }
        SetWindowPos(m_lyrics, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    if (m_library && IsWindowVisible(m_library) && m_libDocked) {
        SetWindowPos(m_library, nullptr, rcMain.right - ov, rcMain.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        SyncWebHostBounds();
    }
    m_syncing = false;
}

void DockManager::SyncWebHostBounds() {
    if (!m_library || !m_webHost) return;
    RECT rcLib{};
    GetWindowRect(m_library, &rcLib);
    int w = rcLib.right - rcLib.left;
    int h = rcLib.bottom - rcLib.top;
    int padX = GlassRenderer::ToPx(4, m_dpi);
    int topY = GlassRenderer::ToPx(24, m_dpi);
    int botY = GlassRenderer::ToPx(18, m_dpi);
    SetWindowPos(m_webHost, nullptr, rcLib.left + padX, rcLib.top + topY, w - padX * 2, h - topY - botY, SWP_NOZORDER | SWP_NOACTIVATE);
}

} // namespace airmuse
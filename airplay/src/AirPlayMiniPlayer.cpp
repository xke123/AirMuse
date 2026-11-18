#include "AirPlayMiniPlayer.hpp"
#include <windowsx.h>
#include <cstdio>
#include <algorithm>

namespace AirPlay {

MiniPlayer::MiniPlayer() = default;

MiniPlayer::~MiniPlayer() {
    Destroy();
}

bool MiniPlayer::Create(HWND parent, int x, int y, int width, int height) {
    m_parent = parent;
    m_x = x;
    m_y = y;
    m_width = width;
    m_height = height;

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = StaticWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"AIRPLAY_MINI_PLAYER_CLASS";
    RegisterClassExW(&wc);

    // AirPlay window flags reversed from 0x46FE87 & 0x46FE8E:
    // Style: WS_POPUP | WS_VISIBLE | WS_CLIPSIBLINGS (0x86000000)
    // ExStyle: WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST (0x88)
    DWORD dwStyle = WS_POPUP | WS_CLIPSIBLINGS;
    DWORD dwExStyle = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;

    m_hwnd = CreateWindowExW(
        dwExStyle,
        wc.lpszClassName,
        L"AirPlay Mini",
        dwStyle,
        m_x, m_y, m_width, m_height,
        nullptr, nullptr, wc.hInstance, this
    );

    if (!m_hwnd) return false;

    // Create 32-bit ARGB DIB section for layered window rendering
    HDC screenDC = GetDC(nullptr);
    m_memDC = CreateCompatibleDC(screenDC);

    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = m_width;
    bmi.bmiHeader.biHeight = -m_height; // Top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    m_memBmp = CreateDIBSection(m_memDC, &bmi, DIB_RGB_COLORS, reinterpret_cast<void**>(&m_dibPixels), nullptr, 0);
    SelectObject(m_memDC, m_memBmp);
    ReleaseDC(nullptr, screenDC);

    // Initialize asset renderer
    m_renderer.Initialize(L"airplay/resources");

    UpdateLayout();

    // Start title scroll animation timer (50ms interval)
    m_timerId = SetTimer(m_hwnd, 1, 50, nullptr);

    ShowWindow(m_hwnd, SW_SHOW);
    Paint();

    return true;
}

void MiniPlayer::Destroy() {
    if (m_timerId && m_hwnd) {
        KillTimer(m_hwnd, m_timerId);
        m_timerId = 0;
    }
    if (m_memBmp) {
        DeleteObject(m_memBmp);
        m_memBmp = nullptr;
    }
    if (m_memDC) {
        DeleteDC(m_memDC);
        m_memDC = nullptr;
    }
    if (m_hwnd) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }
}

void MiniPlayer::Show(bool show) {
    if (m_hwnd) {
        ShowWindow(m_hwnd, show ? SW_SHOW : SW_HIDE);
        if (show) Paint();
    }
}

void MiniPlayer::SetTrackInfo(const std::wstring& title, const std::wstring& artist) {
    m_title = title;
    m_artist = artist;
    m_scrollOffset = 0;
    Invalidate();
}

void MiniPlayer::SetPlaybackState(bool isPlaying) {
    m_isPlaying = isPlaying;
    Invalidate();
}

void MiniPlayer::SetProgress(float progress, int currentSeconds, int totalSeconds) {
    m_progress = std::clamp(progress, 0.0f, 1.0f);
    m_curSec = currentSeconds;
    m_totalSec = totalSeconds;
    Invalidate();
}

void MiniPlayer::SetVolume(float volume) {
    m_volume = std::clamp(volume, 0.0f, 1.0f);
    Invalidate();
}

void MiniPlayer::SetPosition(int x, int y) {
    m_x = x;
    m_y = y;
    if (m_hwnd) {
        SetWindowPos(m_hwnd, nullptr, m_x, m_y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

void MiniPlayer::SetWidth(int width) {
    if (width == m_width) return;
    m_width = width;
    
    // Resize DIB section
    if (m_memBmp) {
        DeleteObject(m_memBmp);
        m_memBmp = nullptr;
    }

    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = m_width;
    bmi.bmiHeader.biHeight = -m_height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    HDC screenDC = GetDC(nullptr);
    m_memBmp = CreateDIBSection(m_memDC, &bmi, DIB_RGB_COLORS, reinterpret_cast<void**>(&m_dibPixels), nullptr, 0);
    SelectObject(m_memDC, m_memBmp);
    ReleaseDC(nullptr, screenDC);

    UpdateLayout();
    Invalidate();
}

void MiniPlayer::UpdateLayout() {
    m_buttons.clear();

    const int padX = Metrics::GLASS_BORDER_THICKNESS + 4; // Left glass margin: 5 + 4 = 9px
    const int btnSize = Metrics::MINI_BUTTON_SIZE;          // 16px
    const int btnY = Metrics::MINI_BUTTON_Y_OFFSET + (m_height - 20) / 2; // Centered vertically

    // 1. Playback Controls from MINICONTROL (96x16)
    // Button order: Prev (0), Play/Pause (1 or 2), Next (4), Stop (3), Menu (5)
    int curX = padX;
    
    // Prev
    m_buttons.push_back({ MINI_BTN_PREV, { curX, btnY, curX + btnSize, btnY + btnSize }, ButtonState::Normal });
    curX += btnSize + 2;

    // Play / Pause toggle
    int playBtnIdx = m_isPlaying ? MINI_BTN_PAUSE : MINI_BTN_PLAY;
    m_buttons.push_back({ playBtnIdx, { curX, btnY, curX + btnSize, btnY + btnSize }, ButtonState::Normal });
    curX += btnSize + 2;

    // Next
    m_buttons.push_back({ MINI_BTN_NEXT, { curX, btnY, curX + btnSize, btnY + btnSize }, ButtonState::Normal });
    curX += btnSize + 2;

    // Stop
    m_buttons.push_back({ MINI_BTN_STOP, { curX, btnY, curX + btnSize, btnY + btnSize }, ButtonState::Normal });
    curX += btnSize + 4;

    // 2. Right-side Window Controls: Close, Minimize, Menu
    int rightX = m_width - Metrics::GLASS_BORDER_THICKNESS - 4;
    
    // Close button (WINDOWBUTTON: 13x13)
    rightX -= Metrics::MINI_WINDOW_BTN_SIZE;
    m_buttons.push_back({ MINI_BTN_CLOSE, { rightX, btnY + 1, rightX + Metrics::MINI_WINDOW_BTN_SIZE, btnY + 1 + Metrics::MINI_WINDOW_BTN_SIZE }, ButtonState::Normal });
    rightX -= 2;

    // Minimize button
    rightX -= Metrics::MINI_WINDOW_BTN_SIZE;
    m_buttons.push_back({ MINI_BTN_MINIMIZE, { rightX, btnY + 1, rightX + Metrics::MINI_WINDOW_BTN_SIZE, btnY + 1 + Metrics::MINI_WINDOW_BTN_SIZE }, ButtonState::Normal });
    rightX -= 4;

    // Menu button (MINICONTROL: 16x16)
    rightX -= btnSize;
    m_buttons.push_back({ MINI_BTN_MENU, { rightX, btnY, rightX + btnSize, btnY + btnSize }, ButtonState::Normal });
    rightX -= 6;

    // 3. Digital Time Display (TIMEFONT): e.g. "03:45" (5 chars * 7px = 35px)
    const int timeWidth = 5 * Metrics::TIMEFONT_CHAR_STEP;
    rightX -= timeWidth;
    m_timeRect = { rightX, btnY + 4, rightX + timeWidth, btnY + 4 + Metrics::TIMEFONT_CHAR_HEIGHT };
    rightX -= 8;

    // 4. Track Title & Artist Text Region
    m_titleRect = { curX + 4, btnY, rightX - 4, btnY + btnSize };
}

int MiniPlayer::HitTest(int x, int y) const {
    POINT pt = { x, y };
    for (size_t i = 0; i < m_buttons.size(); ++i) {
        if (PtInRect(&m_buttons[i].rect, pt)) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

void MiniPlayer::Invalidate() {
    Paint();
}

void MiniPlayer::Paint() {
    if (!m_dibPixels || !m_hwnd) return;

    // Clear buffer to transparent black
    std::fill_n(m_dibPixels, m_width * m_height, 0x00000000);

    // 1. Render AirPlay Glass 9-slice / 3-slice border
    m_renderer.RenderGlassFrame(m_dibPixels, m_width, m_height);

    // 2. Render Control Buttons from MINICONTROL / WINDOWBUTTON
    const auto& miniCtrl = m_renderer.GetMiniControl();
    const auto& winBtns = m_renderer.GetWindowButtons();

    for (size_t i = 0; i < m_buttons.size(); ++i) {
        const auto& btn = m_buttons[i];
        bool isHovered = (m_hoveredBtn == static_cast<int>(i));
        bool isPressed = (m_pressedBtn == static_cast<int>(i));

        // Master alpha: Normal=180 (70%), Hover=255 (100%), Pressed=230 (90%)
        uint8_t alpha = isHovered ? 255 : (isPressed ? 230 : 180);

        if (btn.index <= MINI_BTN_MENU) {
            // Spritesheet MINICONTROL (96x16): each button is 16x16
            int srcX = btn.index * Metrics::MINI_BUTTON_SIZE;
            int dstX = btn.rect.left;
            int dstY = btn.rect.top;
            if (isPressed) dstY += 1; // 1px press indentation

            m_renderer.BlitSprite(m_dibPixels, m_width, m_height, dstX, dstY,
                                  miniCtrl, srcX, 0, Metrics::MINI_BUTTON_SIZE, Metrics::MINI_BUTTON_SIZE, alpha);
        } else {
            // Spritesheet WINDOWBUTTON (130x26): Close=index 7, Minimize=index 6
            int srcX = (btn.index == MINI_BTN_CLOSE) ? 0 : 13;
            int srcY = isHovered ? 13 : 0;
            int dstX = btn.rect.left;
            int dstY = btn.rect.top;
            if (isPressed) dstY += 1;

            m_renderer.BlitSprite(m_dibPixels, m_width, m_height, dstX, dstY,
                                  winBtns, srcX, srcY, Metrics::MINI_WINDOW_BTN_SIZE, Metrics::MINI_WINDOW_BTN_SIZE, alpha);
        }
    }

    // 3. Render Digital Time Digits from TIMEFONT (e.g. "03:45")
    int minutes = m_curSec / 60;
    int seconds = m_curSec % 60;
    char timeBuf[16];
    std::snprintf(timeBuf, sizeof(timeBuf), "%02d:%02d", minutes, seconds);
    m_renderer.DrawTimeDigits(m_dibPixels, m_width, m_height, m_timeRect.left, m_timeRect.top, timeBuf, 220);

    // 4. Render Track Title & Artist Text with Glow Halo Effect
    std::wstring fullText = m_title;
    if (!m_artist.empty()) {
        fullText += L" - " + m_artist;
    }

    HFONT hFont = CreateFontW(
        -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI"
    );
    HGDIOBJ oldFont = SelectObject(m_memDC, hFont);

    // Measure text width
    SIZE textSize = {};
    GetTextExtentPoint32W(m_memDC, fullText.c_str(), static_cast<int>(fullText.length()), &textSize);
    m_titleTextWidth = textSize.cx;

    int textX = m_titleRect.left - m_scrollOffset;
    RECT clipTextRc = m_titleRect;

    // Draw text with glow halo: Text=RGB(230, 230, 230), Glow=RGB(20, 20, 20)
    RECT drawRc = { textX, m_titleRect.top + 1, textX + m_titleTextWidth, m_titleRect.bottom };
    
    // Save DC state before clipping
    HRGN hClipRgn = CreateRectRgn(clipTextRc.left, clipTextRc.top, clipTextRc.right, clipTextRc.bottom);
    SelectClipRgn(m_memDC, hClipRgn);

    m_renderer.DrawGlowText(
        m_memDC, fullText, drawRc,
        RGB(235, 235, 235), // Foreground crisp white-silver
        RGB(15, 15, 15),     // Deep dark halo shadow
        1,                   // 1px halo radius (Zion's compact halo)
        DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX
    );

    SelectClipRgn(m_memDC, nullptr);
    DeleteObject(hClipRgn);

    SelectObject(m_memDC, oldFont);
    DeleteObject(hFont);

    // 5. Submit Layered Surface to Windows DWM compositor
    GlassRenderer::UpdateLayeredSurface(m_hwnd, m_memDC, m_x, m_y, m_width, m_height, 255);
}

LRESULT CALLBACK MiniPlayer::StaticWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    MiniPlayer* self = nullptr;
    if (uMsg == WM_NCCREATE) {
        auto cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        self = reinterpret_cast<MiniPlayer*>(cs->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<MiniPlayer*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }

    if (self) {
        return self->HandleMessage(uMsg, wParam, lParam);
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

LRESULT MiniPlayer::HandleMessage(UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_TIMER: {
        if (wParam == 1 && m_isPlaying) {
            // Scroll title text when longer than visible region
            int availWidth = m_titleRect.right - m_titleRect.left;
            if (m_titleTextWidth > availWidth) {
                m_scrollOffset += 1;
                if (m_scrollOffset > m_titleTextWidth + 30) {
                    m_scrollOffset = -20; // Pause and loop
                }
                Invalidate();
            }
        }
        return 0;
    }

    case WM_SETFOCUS:
    case WM_KILLFOCUS: {
        m_renderer.SetFocused(uMsg == WM_SETFOCUS);
        Invalidate();
        return 0;
    }

    case WM_MOUSEMOVE: {
        int mouseX = GET_X_LPARAM(lParam);
        int mouseY = GET_Y_LPARAM(lParam);

        if (m_isDraggingWindow) {
            POINT ptScreen = { mouseX, mouseY };
            ClientToScreen(m_hwnd, &ptScreen);
            int newX = m_dragStartWindow.x + (ptScreen.x - m_dragStartMouse.x);
            int newY = m_dragStartWindow.y + (ptScreen.y - m_dragStartMouse.y);
            SetPosition(newX, newY);
            return 0;
        }

        // Track hover
        int hit = HitTest(mouseX, mouseY);
        if (hit != m_hoveredBtn) {
            m_hoveredBtn = hit;
            Invalidate();

            // Request mouse leave tracking
            TRACKMOUSEEVENT tme = {};
            tme.cbSize = sizeof(TRACKMOUSEEVENT);
            tme.dwFlags = TME_LEAVE;
            tme.hwndTrack = m_hwnd;
            TrackMouseEvent(&tme);
        }
        return 0;
    }

    case WM_MOUSELEAVE: {
        if (m_hoveredBtn != -1) {
            m_hoveredBtn = -1;
            Invalidate();
        }
        return 0;
    }

    case WM_LBUTTONDOWN: {
        int mouseX = GET_X_LPARAM(lParam);
        int mouseY = GET_Y_LPARAM(lParam);
        int hit = HitTest(mouseX, mouseY);

        if (hit != -1) {
            m_pressedBtn = hit;
            SetCapture(m_hwnd);
            Invalidate();
        } else {
            // Window drag initiate
            m_isDraggingWindow = true;
            GetCursorPos(&m_dragStartMouse);
            m_dragStartWindow = { m_x, m_y };
            SetCapture(m_hwnd);
        }
        return 0;
    }

    case WM_LBUTTONUP: {
        if (m_isDraggingWindow) {
            m_isDraggingWindow = false;
            ReleaseCapture();
            return 0;
        }

        if (m_pressedBtn != -1) {
            int mouseX = GET_X_LPARAM(lParam);
            int mouseY = GET_Y_LPARAM(lParam);
            int hit = HitTest(mouseX, mouseY);

            if (hit == m_pressedBtn) {
                // Trigger button action
                int btnIndex = m_buttons[m_pressedBtn].index;
                switch (btnIndex) {
                case MINI_BTN_PREV:
                    PostMessageW(m_parent, WM_AIRPLAY_COMMAND, CMD_PREV, 0);
                    break;
                case MINI_BTN_PLAY:
                case MINI_BTN_PAUSE:
                    PostMessageW(m_parent, WM_AIRPLAY_COMMAND, m_isPlaying ? CMD_PAUSE : CMD_PLAY, 0);
                    m_isPlaying = !m_isPlaying;
                    UpdateLayout();
                    break;
                case MINI_BTN_NEXT:
                    PostMessageW(m_parent, WM_AIRPLAY_COMMAND, CMD_NEXT, 0);
                    break;
                case MINI_BTN_STOP:
                    PostMessageW(m_parent, WM_AIRPLAY_COMMAND, CMD_STOP, 0);
                    m_isPlaying = false;
                    UpdateLayout();
                    break;
                case MINI_BTN_CLOSE:
                    Destroy();
                    break;
                case MINI_BTN_MINIMIZE:
                    ShowWindow(m_hwnd, SW_MINIMIZE);
                    break;
                case MINI_BTN_MENU:
                    // Toggle normal/mini mode
                    PostMessageW(m_parent, WM_AIRPLAY_NOTIFY, 0, 0);
                    break;
                }
            }

            m_pressedBtn = -1;
            ReleaseCapture();
            Invalidate();
        }
        return 0;
    }

    case WM_RBUTTONUP: {
        // Right click opens context menu
        POINT pt;
        GetCursorPos(&pt);
        HMENU hMenu = CreatePopupMenu();
        AppendMenuW(hMenu, MF_STRING, 101, L"切换至常规模式 (&N)");
        AppendMenuW(hMenu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(hMenu, MF_STRING, 102, L"总在最前 (&T)");
        AppendMenuW(hMenu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(hMenu, MF_STRING, 103, L"退出 AirPlay (&X)");

        int cmd = TrackPopupMenu(hMenu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, m_hwnd, nullptr);
        DestroyMenu(hMenu);

        if (cmd == 101) {
            PostMessageW(m_parent, WM_AIRPLAY_NOTIFY, 0, 0);
        } else if (cmd == 103) {
            Destroy();
        }
        return 0;
    }

    case WM_NCHITTEST:
        return HTCLIENT;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

} // namespace AirPlay

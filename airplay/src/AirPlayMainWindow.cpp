#include "AirPlayMainWindow.hpp"

namespace AirPlay {

MainWindow::MainWindow() = default;
MainWindow::~MainWindow() = default;

bool MainWindow::Create() {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = StaticWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = WINDOW_CLASS_BASE;
    RegisterClassExW(&wc);

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED,
        WINDOW_CLASS_BASE,
        WINDOW_NAME_MAIN,
        WS_POPUP | WS_VISIBLE,
        m_normX, m_normY, m_normW, m_normH,
        nullptr, nullptr, wc.hInstance, this
    );

    if (!m_hwnd) return false;

    // Create MiniPlayer instance
    m_miniPlayer = std::make_unique<MiniPlayer>();
    m_miniPlayer->Create(m_hwnd, m_miniX, m_miniY, m_miniW, m_miniH);
    m_miniPlayer->Show(false); // Initially hidden in normal mode

    return true;
}

void MainWindow::RunMessageLoop() {
    MSG msg = {};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void MainWindow::SwitchMode(PlayerWindowMode mode) {
    if (m_mode == mode) return;
    m_mode = mode;

    if (m_mode == PlayerWindowMode::Mini) {
        // Save normal window pos
        RECT rc;
        GetWindowRect(m_hwnd, &rc);
        m_normX = rc.left;
        m_normY = rc.top;

        ShowWindow(m_hwnd, SW_HIDE);
        m_miniPlayer->SetPosition(m_normX, m_normY);
        m_miniPlayer->Show(true);
    } else {
        // Save mini pos
        if (m_miniPlayer->GetHwnd()) {
            RECT rc;
            GetWindowRect(m_miniPlayer->GetHwnd(), &rc);
            m_miniX = rc.left;
            m_miniY = rc.top;
        }

        m_miniPlayer->Show(false);
        SetWindowPos(m_hwnd, nullptr, m_miniX, m_miniY, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW);
    }
}

void MainWindow::CheckSnapToTaskbar() {
    // AirPlay binary checks for "Shell_TrayWnd" (0x536B58 slot 23)
    HWND taskbarHwnd = FindWindowW(L"Shell_TrayWnd", nullptr);
    if (!taskbarHwnd) return;

    RECT taskbarRc;
    GetWindowRect(taskbarHwnd, &taskbarRc);

    HWND targetHwnd = (m_mode == PlayerWindowMode::Mini) ? m_miniPlayer->GetHwnd() : m_hwnd;
    if (!targetHwnd) return;

    RECT wndRc;
    GetWindowRect(targetHwnd, &wndRc);

    const int snapDistance = 15;
    // Top taskbar snap
    if (std::abs(wndRc.top - taskbarRc.bottom) < snapDistance) {
        SetWindowPos(targetHwnd, nullptr, wndRc.left, taskbarRc.bottom, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    }
    // Bottom taskbar snap
    else if (std::abs(wndRc.bottom - taskbarRc.top) < snapDistance) {
        SetWindowPos(targetHwnd, nullptr, wndRc.left, taskbarRc.top - (wndRc.bottom - wndRc.top), 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    }
}

LRESULT CALLBACK MainWindow::StaticWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    MainWindow* self = nullptr;
    if (uMsg == WM_NCCREATE) {
        auto cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        self = reinterpret_cast<MainWindow*>(cs->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }

    if (self) {
        return self->HandleMessage(uMsg, wParam, lParam);
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

LRESULT MainWindow::HandleMessage(UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_AIRPLAY_COMMAND: {
        // Forward command to audio engine
        return 0;
    }
    case WM_AIRPLAY_NOTIFY: {
        // Toggle normal/mini mode
        SwitchMode(m_mode == PlayerWindowMode::Normal ? PlayerWindowMode::Mini : PlayerWindowMode::Normal);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(m_hwnd, uMsg, wParam, lParam);
}

} // namespace AirPlay

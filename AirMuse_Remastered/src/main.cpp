#include <shobjidl.h>
#include "core/WinCommon.hpp"
#include <winrt/Windows.Foundation.h>
#include "core/AppController.hpp"
#include "ui/DockManager.hpp"
#include "ui/MainWindow.hpp"
#include "ui/LyricsWindow.hpp"
#include "ui/LibraryWindow.hpp"
#include "ui/TestPanelWindow.hpp"

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int) {
    SetCurrentProcessExplicitAppUserModelID(L"AirMuse.Player");
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::single_threaded);

    Gdiplus::GdiplusStartupInput gdiInput;
    ULONG_PTR gdiToken = 0;
    Gdiplus::GdiplusStartup(&gdiToken, &gdiInput, nullptr);

    airmuse::AppController controller;
    airmuse::DockManager dockMgr;

    airmuse::MainWindow mainWnd(hInst, controller, dockMgr);
    HWND hwndMain = mainWnd.Create();

    airmuse::LyricsWindow lyricsWnd(hInst, controller, dockMgr);
    HWND hwndLyrics = lyricsWnd.Create(hwndMain);

    airmuse::LibraryWindow libraryWnd(hInst, controller, dockMgr);
    HWND hwndLib = libraryWnd.Create(hwndMain);

    airmuse::TestPanelWindow testPanel(hInst, controller, dockMgr);
    testPanel.Create(hwndMain);

    mainWnd.BindChildWindows(&lyricsWnd, &libraryWnd);
    mainWnd.BindTestPanel(&testPanel);
    dockMgr.AttachWindows(hwndMain, hwndLyrics, hwndLib, libraryWnd.WebHostHwnd());

    controller.Initialize(hwndMain, libraryWnd.WebHostHwnd());
    ShowWindow(hwndMain, SW_SHOW);
    mainWnd.StartIntroSequence();

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    Gdiplus::GdiplusShutdown(gdiToken);
    return static_cast<int>(msg.wParam);
}
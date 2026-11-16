#include <unknwn.h>
#include <objidl.h>
#include "WebSourceProvider.hpp"
#include <WebView2.h>
#include <wrl.h>
#include <shlobj.h>
#include <winrt/Windows.Data.Json.h>
#include <mutex>
#include <cstdio>
#include <algorithm>

using namespace Microsoft::WRL;
using namespace winrt::Windows::Data::Json;

namespace airmuse {

struct WebSourceProvider::Impl {
    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    bool visible = false;
    mutable std::mutex mutex;
    NowPlayingState state;
};

namespace {
std::wstring GetWebViewUserDataFolder() {
    PWSTR localAppData = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &localAppData)) && localAppData) {
        dir = std::wstring(localAppData) + L"\\AirMuse\\WebView2";
        CoTaskMemFree(localAppData);
    }
    return dir;
}
} // namespace

WebSourceProvider::~WebSourceProvider() { Shutdown(); }

bool WebSourceProvider::Initialize(HWND hostHwnd, HWND notifyHwnd, UINT notifyMsg) {
    m_hostHwnd = hostHwnd;
    m_notifyHwnd = notifyHwnd;
    m_notifyMsg = notifyMsg;
    if (!m_impl) m_impl = new Impl();

    std::wstring userData = GetWebViewUserDataFolder();
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, userData.empty() ? nullptr : userData.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [this](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result) || !env || !m_impl) return result;
                m_impl->env = env;
                env->CreateCoreWebView2Controller(
                    m_hostHwnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [this](HRESULT ctrlRes, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(ctrlRes) || !controller || !m_impl) return ctrlRes;
                            m_impl->controller = controller;
                            controller->get_CoreWebView2(&m_impl->webview);

                            ComPtr<ICoreWebView2Controller2> ctrl2;
                            if (SUCCEEDED(controller->QueryInterface(IID_PPV_ARGS(&ctrl2))) && ctrl2) {
                                ctrl2->put_DefaultBackgroundColor({ 255, 28, 29, 32 });
                            }

                            if (m_impl->webview) {
                                m_impl->webview->add_WebMessageReceived(
                                    Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                        [this](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                            if (!args || !m_impl) return S_OK;
                                            LPWSTR raw = nullptr;
                                            if (SUCCEEDED(args->TryGetWebMessageAsString(&raw)) && raw) {
                                                JsonObject obj;
                                                if (JsonObject::TryParse(raw, obj)) {
                                                    auto msgType = obj.GetNamedString(L"type", L"");
                                                    if (msgType == L"userStatus") {
                                                        std::lock_guard lock(m_impl->mutex);
                                                        m_impl->state.webUserName = obj.GetNamedString(L"userName", L"").c_str();
                                                        if (m_notifyHwnd && IsWindow(m_notifyHwnd) && m_notifyMsg) {
                                                            PostMessageW(m_notifyHwnd, m_notifyMsg, 0, 0);
                                                        }
                                                    } else if (msgType == L"nowPlaying") {
                                                        std::lock_guard lock(m_impl->mutex);
                                                        m_impl->state.providerId    = L"embedded_web";
                                                        m_impl->state.sourceName    = obj.GetNamedString(L"source", L"Web Player").c_str();
                                                        m_impl->state.title         = obj.GetNamedString(L"title", L"").c_str();
                                                        m_impl->state.artist        = obj.GetNamedString(L"artist", L"").c_str();
                                                        m_impl->state.album         = obj.GetNamedString(L"album", L"").c_str();
                                                        m_impl->state.contextTitle  = obj.GetNamedString(L"contextTitle", L"").c_str();
                                                        m_impl->state.contextType   = obj.GetNamedString(L"contextType", L"").c_str();
                                                        std::wstring uName = obj.GetNamedString(L"userName", L"").c_str();
                                                        if (!uName.empty()) m_impl->state.webUserName = uName;
                                                        m_impl->state.isPlaying     = obj.GetNamedBoolean(L"isPlaying", false);
                                                        m_impl->state.positionMs    = static_cast<int64_t>(obj.GetNamedNumber(L"positionMs", 0.0));
                                                        m_impl->state.durationMs    = static_cast<int64_t>(obj.GetNamedNumber(L"durationMs", 0.0));
                                                        m_impl->state.timestampTick = GetTickCount64();
                                                        auto spec = GetWebAdapterSpec(m_platform);
                                                        m_impl->state.caps.canSeek  = (spec.seekJsTemplate[0] != L'\0');
                                                        if (m_notifyHwnd && IsWindow(m_notifyHwnd) && m_notifyMsg) {
                                                            PostMessageW(m_notifyHwnd, m_notifyMsg, 0, 0);
                                                        }
                                                    }
                                                }
                                                CoTaskMemFree(raw);
                                            }
                                            return S_OK;
                                        }).Get(), nullptr);

                                m_impl->webview->add_NavigationCompleted(
                                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                                        [this](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
                                            if (sender) {
                                                auto spec = GetWebAdapterSpec(m_platform);
                                                sender->ExecuteScript(spec.injectScript, nullptr);
                                            }
                                            return S_OK;
                                        }).Get(), nullptr);

                                m_impl->webview->AddScriptToExecuteOnDocumentCreated(GetWebAdapterSpec(m_platform).injectScript, nullptr);
                                SwitchPlatform(m_platform);
                            }

                            RECT rc{};
                            GetClientRect(m_hostHwnd, &rc);
                            m_impl->controller->put_Bounds(rc);
                            m_impl->controller->put_IsVisible(m_impl->visible ? TRUE : FALSE);
                            return S_OK;
                        }).Get());
                return S_OK;
            }).Get());
    return SUCCEEDED(hr);
}

void WebSourceProvider::SwitchPlatform(WebPlatform platform) {
    m_platform = platform;
    if (m_impl) {
        std::lock_guard lock(m_impl->mutex);
        m_impl->state.webUserName.clear();
    }
    if (!m_impl || !m_impl->webview) return;
    auto spec = GetWebAdapterSpec(platform);
    m_impl->webview->AddScriptToExecuteOnDocumentCreated(spec.injectScript, nullptr);
    m_impl->webview->Navigate(spec.homeUrl);
}

bool WebSourceProvider::IsAvailable() const {
    if (!m_impl) return false;
    std::lock_guard lock(m_impl->mutex);
    return !m_impl->state.title.empty();
}

NowPlayingState WebSourceProvider::GetState() const {
    if (!m_impl) return NowPlayingState{};
    std::lock_guard lock(m_impl->mutex);
    return m_impl->state;
}

void WebSourceProvider::PlayPause() { if (m_impl && m_impl->webview) m_impl->webview->ExecuteScript(GetWebAdapterSpec(m_platform).playPauseJs, nullptr); }
void WebSourceProvider::Stop()      { PlayPause(); }
void WebSourceProvider::Next()      { if (m_impl && m_impl->webview) m_impl->webview->ExecuteScript(GetWebAdapterSpec(m_platform).nextJs, nullptr); }
void WebSourceProvider::Previous()  { if (m_impl && m_impl->webview) m_impl->webview->ExecuteScript(GetWebAdapterSpec(m_platform).prevJs, nullptr); }

void WebSourceProvider::SeekTo(int64_t positionMs) {
    if (!m_impl || !m_impl->webview) return;
    auto spec = GetWebAdapterSpec(m_platform);
    if (!spec.seekJsTemplate || spec.seekJsTemplate[0] == L'\0') return;
    double sec = static_cast<double>(positionMs) / 1000.0;
    wchar_t js[256];
    swprintf_s(js, spec.seekJsTemplate, sec);
    m_impl->webview->ExecuteScript(js, nullptr);
}

void WebSourceProvider::SetVolume(float volume0to1) {
    if (!m_impl || !m_impl->webview) return;
    float v = std::clamp(volume0to1, 0.0f, 1.0f);
    {
        std::lock_guard lock(m_impl->mutex);
        m_impl->state.volume = v;
    }
    wchar_t js[256];
    swprintf_s(js, L"(function(){document.querySelectorAll('audio,video').forEach(el=>el.volume=%.2f);const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.volume=%.2f;})();", v, v);
    m_impl->webview->ExecuteScript(js, nullptr);
}

void WebSourceProvider::Resize(int widthPx, int heightPx) {
    if (m_impl && m_impl->controller) m_impl->controller->put_Bounds({ 0, 0, widthPx, heightPx });
}

void WebSourceProvider::SetVisible(bool visible) {
    if (!m_impl) return;
    m_impl->visible = visible;
    if (m_impl->controller) m_impl->controller->put_IsVisible(visible ? TRUE : FALSE);
}

std::wstring WebSourceProvider::GetLoggedInUser() const {
    if (!m_impl) return L"";
    std::lock_guard lock(m_impl->mutex);
    return m_impl->state.webUserName;
}

void WebSourceProvider::NavigateToPlayingContext() {
    if (!m_impl || !m_impl->webview) return;
    m_impl->webview->ExecuteScript(L"if(window.__airmuseJumpToPlaying) window.__airmuseJumpToPlaying();", nullptr);
}

void WebSourceProvider::Shutdown() {
    if (!m_impl) return;
    if (m_impl->controller) { m_impl->controller->Close(); m_impl->controller.Reset(); }
    m_impl->webview.Reset();
    m_impl->env.Reset();
    delete m_impl;
    m_impl = nullptr;
}

} // namespace airmuse


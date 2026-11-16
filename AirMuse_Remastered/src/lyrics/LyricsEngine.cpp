#include "LyricsEngine.hpp"
#include <winhttp.h>
#include <wincrypt.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <algorithm>
#include <thread>
#include <future>
#include <cwctype>
#include <cmath>

using namespace winrt::Windows::Data::Json;

namespace airmuse {

namespace {

std::string WideToUtf8(std::wstring const& ws) {
    if (ws.empty()) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), static_cast<int>(ws.size()), nullptr, 0, nullptr, nullptr);
    std::string out(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), static_cast<int>(ws.size()), out.data(), len, nullptr, nullptr);
    return out;
}

std::wstring Utf8ToWide(std::string const& s) {
    if (s.empty()) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), len);
    return out;
}

std::string Base64DecodeUtf8(std::string const& b64) {
    if (b64.empty()) return {};
    DWORD outLen = 0;
    if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()), CRYPT_STRING_BASE64, nullptr, &outLen, nullptr, nullptr)) return {};
    std::string out(outLen, '\0');
    if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()), CRYPT_STRING_BASE64, reinterpret_cast<BYTE*>(out.data()), &outLen, nullptr, nullptr)) return {};
    out.resize(outLen);
    return out;
}

std::wstring UrlEncode(std::wstring const& ws) {
    std::string utf8 = WideToUtf8(ws);
    std::wstring out;
    const wchar_t hex[] = L"0123456789ABCDEF";
    for (unsigned char c : utf8) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<wchar_t>(c));
        } else if (c == ' ') {
            out.push_back(L'+');
        } else {
            out.push_back(L'%');
            out.push_back(hex[(c >> 4) & 0xF]);
            out.push_back(hex[c & 0xF]);
        }
    }
    return out;
}

std::wstring NormalizeText(std::wstring const& s) {
    std::wstring out;
    bool inParen = false;
    for (wchar_t c : s) {
        if (c == L'(' || c == L'（' || c == L'[') { inParen = true; continue; }
        if (c == L')' || c == L'）' || c == L']') { inParen = false; continue; }
        if (inParen) continue;
        if (std::iswalnum(c) || (c >= 0x4E00 && c <= 0x9FFF)) {
            out.push_back(static_cast<wchar_t>(std::towlower(c)));
        }
    }
    return out;
}

std::wstring CleanArtistName(std::wstring const& artist) {
    size_t dash = artist.find(L" — ");
    if (dash == std::wstring::npos) dash = artist.find(L" - ");
    std::wstring res = (dash != std::wstring::npos) ? artist.substr(0, dash) : artist;
    while (!res.empty() && res.back() == L' ') res.pop_back();
    return res;
}

std::string HttpGetUtf8(std::wstring const& host, std::wstring const& path, bool https = true, std::wstring const& extraHeaders = L"") {
    std::string body;
    HINTERNET hSession = WinHttpOpen(L"AirMuse/2.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return body;
    WinHttpSetTimeouts(hSession, 3500, 3500, 3500, 5000);
    HINTERNET hConnect = WinHttpConnect(hSession, host.c_str(), https ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT, 0);
    if (hConnect) {
        HINTERNET hReq = WinHttpOpenRequest(hConnect, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, https ? WINHTTP_FLAG_SECURE : 0);
        if (hReq) {
            if (!extraHeaders.empty()) WinHttpAddRequestHeaders(hReq, extraHeaders.c_str(), static_cast<DWORD>(-1), WINHTTP_ADDREQ_FLAG_ADD);
            if (WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(hReq, nullptr)) {
                DWORD avail = 0;
                while (WinHttpQueryDataAvailable(hReq, &avail) && avail > 0) {
                    std::string chunk(avail, '\0');
                    DWORD read = 0;
                    if (WinHttpReadData(hReq, chunk.data(), avail, &read) && read > 0) body.append(chunk.data(), read);
                    else break;
                }
            }
            WinHttpCloseHandle(hReq);
        }
        WinHttpCloseHandle(hConnect);
    }
    WinHttpCloseHandle(hSession);
    return body;
}

std::vector<LyricLine> ParseLrc(std::wstring const& lrcText) {
    std::vector<LyricLine> result;
    size_t pos = 0;
    while (pos < lrcText.size()) {
        size_t eol = lrcText.find(L'\n', pos);
        if (eol == std::wstring::npos) eol = lrcText.size();
        std::wstring line = lrcText.substr(pos, eol - pos);
        if (!line.empty() && line.back() == L'\r') line.pop_back();
        pos = eol + 1;

        std::vector<int64_t> tags;
        size_t cur = 0;
        while (cur < line.size() && line[cur] == L'[') {
            size_t close = line.find(L']', cur);
            if (close == std::wstring::npos) break;
            std::wstring tag = line.substr(cur + 1, close - cur - 1);
            size_t colon = tag.find(L':');
            if (colon != std::wstring::npos && colon > 0 && std::iswdigit(tag[0])) {
                try {
                    int min = std::stoi(tag.substr(0, colon));
                    double sec = std::stod(tag.substr(colon + 1));
                    tags.push_back(static_cast<int64_t>(min * 60000.0 + sec * 1000.0));
                } catch (...) {}
            }
            cur = close + 1;
        }
        if (!tags.empty()) {
            std::wstring lyric = line.substr(cur);
            while (!lyric.empty() && (lyric.front() == L' ' || lyric.front() == L'\t')) lyric.erase(lyric.begin());
            while (!lyric.empty() && (lyric.back() == L' ' || lyric.back() == L'\t')) lyric.pop_back();
            if (!lyric.empty()) {
                for (int64_t t : tags) result.push_back(LyricLine{ t, lyric, L"" });
            }
        }
    }
    std::sort(result.begin(), result.end(), [](LyricLine const& a, LyricLine const& b) { return a.timeMs < b.timeMs; });
    return result;
}

struct LyricCandidate {
    std::wstring title;
    std::wstring artist;
    int64_t durationMs = 0;
    std::vector<LyricLine> lines;
    int score = -1000;
};

int ScoreCandidate(LyricCandidate const& c, std::wstring const& targetTitle, std::wstring const& targetArtist, int64_t targetDurationMs) {
    if (c.lines.size() < 3) return -1000;
    int s = 0;
    std::wstring nt = NormalizeText(targetTitle);
    std::wstring ct = NormalizeText(c.title);
    if (!nt.empty() && !ct.empty()) {
        if (ct == nt) s += 45;
        else if (ct.find(nt) != std::wstring::npos || nt.find(ct) != std::wstring::npos) s += 25;
    }
    std::wstring na = NormalizeText(CleanArtistName(targetArtist));
    std::wstring ca = NormalizeText(c.artist);
    if (!na.empty() && !ca.empty()) {
        if (ca == na) s += 30;
        else if (ca.find(na) != std::wstring::npos || na.find(ca) != std::wstring::npos) s += 18;
    }
    if (targetDurationMs > 1000 && c.durationMs > 1000) {
        int64_t diff = std::abs(c.durationMs - targetDurationMs);
        if (diff <= 1500) s += 40;
        else if (diff <= 3500) s += 28;
        else if (diff <= 7000) s += 12;
        else if (diff > 15000) s -= 35;
    }
    bool hasTrans = std::any_of(c.lines.begin(), c.lines.end(), [](LyricLine const& ln) { return !ln.trans.empty(); });
    if (hasTrans) s += 8;
    return s;
}

std::vector<LyricCandidate> FetchLrclib(std::wstring const& title, std::wstring const& artist, int64_t durationMs) {
    std::vector<LyricCandidate> out;
    std::wstring cleanArtist = CleanArtistName(artist);
    std::wstring path = L"/api/get?track_name=" + UrlEncode(title) + L"&artist_name=" + UrlEncode(cleanArtist);
    if (durationMs > 1000) path += L"&duration=" + std::to_wstring(durationMs / 1000);
    std::string raw = HttpGetUtf8(L"lrclib.net", path, true);
    if (!raw.empty()) {
        JsonObject obj{ nullptr };
        if (JsonObject::TryParse(Utf8ToWide(raw), obj) && obj.HasKey(L"syncedLyrics") &&
            obj.GetNamedValue(L"syncedLyrics").ValueType() == JsonValueType::String) {
            LyricCandidate c;
            c.title = obj.HasKey(L"trackName") ? std::wstring(obj.GetNamedString(L"trackName").c_str()) : title;
            c.artist = obj.HasKey(L"artistName") ? std::wstring(obj.GetNamedString(L"artistName").c_str()) : cleanArtist;
            c.durationMs = obj.HasKey(L"duration") && obj.GetNamedValue(L"duration").ValueType() == JsonValueType::Number
                ? static_cast<int64_t>(obj.GetNamedNumber(L"duration") * 1000.0) : durationMs;
            c.lines = ParseLrc(std::wstring(obj.GetNamedString(L"syncedLyrics").c_str()));
            if (!c.lines.empty()) out.push_back(std::move(c));
        }
    }
    return out;
}

std::vector<LyricCandidate> FetchNetEase(std::wstring const& title, std::wstring const& artist) {
    std::vector<LyricCandidate> out;
    std::wstring cleanArtist = CleanArtistName(artist);
    std::wstring hdr = L"Referer: https://music.163.com/\r\n";
    std::string sraw = HttpGetUtf8(L"music.163.com", L"/api/search/get/web?s=" + UrlEncode(title + L" " + cleanArtist) + L"&type=1&limit=3", true, hdr);
    if (sraw.empty()) return out;
    JsonObject root{ nullptr };
    if (!JsonObject::TryParse(Utf8ToWide(sraw), root) || !root.HasKey(L"result")) return out;
    auto res = root.GetNamedObject(L"result");
    if (!res.HasKey(L"songs")) return out;
    auto songs = res.GetNamedArray(L"songs");
    for (uint32_t i = 0; i < std::min<uint32_t>(songs.Size(), 3); ++i) {
        auto song = songs.GetAt(i).GetObject();
        int64_t songId = static_cast<int64_t>(song.GetNamedNumber(L"id"));
        LyricCandidate c;
        c.title = song.GetNamedString(L"name", L"").c_str();
        c.durationMs = static_cast<int64_t>(song.GetNamedNumber(L"duration", 0.0));
        auto arts = song.GetNamedArray(L"artists");
        if (arts.Size() > 0) c.artist = arts.GetAt(0).GetObject().GetNamedString(L"name", L"").c_str();

        std::string lraw = HttpGetUtf8(L"music.163.com", L"/api/song/lyric?id=" + std::to_wstring(songId) + L"&lv=1&tv=1", true, hdr);
        JsonObject lobj{ nullptr };
        if (JsonObject::TryParse(Utf8ToWide(lraw), lobj) && lobj.HasKey(L"lrc")) {
            c.lines = ParseLrc(std::wstring(lobj.GetNamedObject(L"lrc").GetNamedString(L"lyric", L"").c_str()));
            if (c.lines.empty()) continue;
            if (lobj.HasKey(L"tlyric") && lobj.GetNamedValue(L"tlyric").ValueType() == JsonValueType::Object) {
                auto tlines = ParseLrc(std::wstring(lobj.GetNamedObject(L"tlyric").GetNamedString(L"lyric", L"").c_str()));
                for (auto& ln : c.lines) {
                    for (auto const& tl : tlines) {
                        if (std::abs(tl.timeMs - ln.timeMs) <= 250) { ln.trans = tl.text; break; }
                    }
                }
            }
            out.push_back(std::move(c));
        }
    }
    return out;
}

std::vector<LyricCandidate> FetchKugou(std::wstring const& title, std::wstring const& artist, int64_t durationMs) {
    std::vector<LyricCandidate> out;
    std::wstring cleanArtist = CleanArtistName(artist);
    std::wstring path = L"/search?ver=1&man=yes&client=pc&keyword=" + UrlEncode(title + L" " + cleanArtist);
    if (durationMs > 1000) path += L"&duration=" + std::to_wstring(durationMs);
    std::string raw = HttpGetUtf8(L"krcs.kugou.com", path, true);
    JsonObject root{ nullptr };
    if (!JsonObject::TryParse(Utf8ToWide(raw), root) || !root.HasKey(L"candidates")) return out;
    auto cands = root.GetNamedArray(L"candidates");
    for (uint32_t i = 0; i < std::min<uint32_t>(cands.Size(), 2); ++i) {
        auto item = cands.GetAt(i).GetObject();
        std::wstring id = item.GetNamedString(L"id", L"").c_str();
        std::wstring key = item.GetNamedString(L"accesskey", L"").c_str();
        std::string dl = HttpGetUtf8(L"krcs.kugou.com", L"/download?ver=1&client=pc&id=" + id + L"&accesskey=" + key + L"&charset=utf8&fmt=lrc", true);
        JsonObject dlObj{ nullptr };
        if (JsonObject::TryParse(Utf8ToWide(dl), dlObj) && dlObj.HasKey(L"content")) {
            std::string decoded = Base64DecodeUtf8(WideToUtf8(std::wstring(dlObj.GetNamedString(L"content").c_str())));
            LyricCandidate c;
            c.title = item.GetNamedString(L"song", L"").c_str();
            c.artist = item.GetNamedString(L"singer", L"").c_str();
            c.durationMs = static_cast<int64_t>(item.GetNamedNumber(L"duration", 0.0));
            c.lines = ParseLrc(Utf8ToWide(decoded));
            if (!c.lines.empty()) out.push_back(std::move(c));
        }
    }
    return out;
}

} // namespace

void LyricsEngine::Initialize(HWND notifyHwnd, UINT notifyMsg) {
    m_hwnd = notifyHwnd;
    m_notifyMsg = notifyMsg;
}

void LyricsEngine::RequestLyrics(std::wstring const& title, std::wstring const& artist, int64_t durationMs) {
    if (title.empty()) return;
    std::wstring key = title + L"|" + artist;
    {
        std::lock_guard lock(m_mutex);
        if (m_current.trackKey == key) return;
        m_current.trackKey = key;
        m_current.offsetMs = m_offsets.count(key) ? m_offsets[key] : 0;

        auto it = m_cache.find(key);
        if (it != m_cache.end()) {
            m_current.lines = it->second;
            m_current.loading = false;
            m_current.statusText = it->second.empty() ? L"暂无匹配歌词" : L"";
            NotifyUI();
            return;
        }
        m_current.lines.clear();
        m_current.loading = true;
        m_current.statusText = L"正在搜索多源歌词...";
    }
    NotifyUI();
    std::thread(&LyricsEngine::FetchWorker, this, key, title, artist, durationMs).detach();
}

void LyricsEngine::AdjustOffset(std::wstring const& trackKey, int64_t deltaMs) {
    std::lock_guard lock(m_mutex);
    m_offsets[trackKey] += deltaMs;
    if (m_current.trackKey == trackKey) m_current.offsetMs = m_offsets[trackKey];
}

void LyricsEngine::FetchWorker(std::wstring key, std::wstring title, std::wstring artist, int64_t durationMs) {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto fLrc = std::async(std::launch::async, [&]() { return FetchLrclib(title, artist, durationMs); });
    auto fNe  = std::async(std::launch::async, [&]() { return FetchNetEase(title, artist); });
    auto fKg  = std::async(std::launch::async, [&]() { return FetchKugou(title, artist, durationMs); });

    std::vector<LyricCandidate> all;
    for (auto* f : { &fLrc, &fNe, &fKg }) {
        try {
            auto part = f->get();
            all.insert(all.end(), std::make_move_iterator(part.begin()), std::make_move_iterator(part.end()));
        } catch (...) {}
    }

    std::vector<LyricLine> bestLines;
    int bestScore = -1000;
    for (auto& c : all) {
        c.score = ScoreCandidate(c, title, artist, durationMs);
        if (c.score > bestScore) { bestScore = c.score; bestLines = std::move(c.lines); }
    }

    {
        std::lock_guard lock(m_mutex);
        m_cache[key] = bestLines;
        if (m_current.trackKey == key) {
            m_current.lines = std::move(bestLines);
            m_current.loading = false;
            m_current.statusText = m_current.lines.empty() ? L"暂无匹配歌词" : L"";
        }
    }
    NotifyUI();
}

LyricsSnapshot LyricsEngine::GetSnapshot() const {
    std::lock_guard lock(m_mutex);
    return m_current;
}

void LyricsEngine::NotifyUI() {
    if (m_hwnd && IsWindow(m_hwnd)) PostMessageW(m_hwnd, m_notifyMsg, 0, 0);
}

} // namespace airmuse
#include "AirPlayGlassRenderer.hpp"
#include <fstream>
#include <cmath>
#include <algorithm>

namespace AirPlay {

static inline uint32_t BlendPixel(uint32_t bg, uint32_t fg, uint8_t masterAlpha) {
    uint32_t fgA = (fg >> 24) & 0xFF;
    if (masterAlpha < 255) {
        fgA = (fgA * masterAlpha) >> 8;
    }
    if (fgA == 0) return bg;
    if (fgA == 255) return fg;

    uint32_t fgR = (fg >> 16) & 0xFF;
    uint32_t fgG = (fg >> 8) & 0xFF;
    uint32_t fgB = fg & 0xFF;

    uint32_t bgA = (bg >> 24) & 0xFF;
    uint32_t bgR = (bg >> 16) & 0xFF;
    uint32_t bgG = (bg >> 8) & 0xFF;
    uint32_t bgB = bg & 0xFF;

    uint32_t invA = 255 - fgA;
    uint32_t outA = fgA + ((bgA * invA) >> 8);
    uint32_t outR = fgR + ((bgR * invA) >> 8);
    uint32_t outG = fgG + ((bgG * invA) >> 8);
    uint32_t outB = fgB + ((bgB * invA) >> 8);

    return (std::min(outA, 255u) << 24) |
           (std::min(outR, 255u) << 16) |
           (std::min(outG, 255u) << 8)  |
            std::min(outB, 255u);
}

GlassRenderer::GlassRenderer() = default;
GlassRenderer::~GlassRenderer() = default;

static bool LoadRleFile(const std::wstring& path, RleCodec::Bitmap32& bmp) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) return false;
    std::streamsize sz = f.tellg();
    f.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(sz);
    if (!f.read(reinterpret_cast<char*>(buf.data()), sz)) return false;
    try {
        bmp = RleCodec::Decode(buf.data(), buf.size());
        return true;
    } catch (...) {
        return false;
    }
}

bool GlassRenderer::Initialize(const std::wstring& assetDir) {
    LoadRleFile(assetDir + L"/raw_rcdata/WINDOWGLASS.bin", m_glassNormal);
    LoadRleFile(assetDir + L"/raw_rcdata/WINDOWGLASSFOCUS.bin", m_glassFocused);
    LoadRleFile(assetDir + L"/raw_rcdata/MINICONTROL.bin", m_miniControl);
    LoadRleFile(assetDir + L"/raw_rcdata/MINIFONT.bin", m_miniFont);
    LoadRleFile(assetDir + L"/raw_rcdata/TIMEFONT.bin", m_timeFont);
    LoadRleFile(assetDir + L"/raw_rcdata/WINDOWBUTTON.bin", m_windowButton);
    LoadRleFile(assetDir + L"/raw_rcdata/MAINCONTROL.bin", m_mainControl);
    LoadRleFile(assetDir + L"/raw_rcdata/HINTGLASS.bin", m_hintGlass);
    return true;
}

void GlassRenderer::SetFocused(bool focused) {
    m_focused = focused;
}

const RleCodec::Bitmap32& GlassRenderer::GetGlassAsset() const {
    return m_focused ? m_glassFocused : m_glassNormal;
}

void GlassRenderer::RenderGlassFrame(uint32_t* targetPixels, int targetWidth, int targetHeight) {
    const auto& glass = GetGlassAsset();
    if (glass.width == 0 || glass.height == 0) return;

    // AirPlay 9-slice / 3-slice border metrics:
    // Left/Right cap: 5px
    // Top/Bottom cap: 20px (glass.height / 2)
    const int capW = Metrics::GLASS_BORDER_THICKNESS; // 5
    const int capH = Metrics::GLASS_CAP_HEIGHT;       // 20
    const int midSrcX = capW;                         // 5
    const int midSrcW = glass.width - capW * 2;       // 30 - 10 = 20

    // 1. Top Bar: Left (5x20) -> Center stretched -> Right (5x20)
    // Left cap
    BlitSprite(targetPixels, targetWidth, targetHeight, 0, 0,
               glass, 0, 0, capW, capH);
    // Center horizontal repeat/stretch
    int curX = capW;
    int endX = targetWidth - capW;
    while (curX < endX) {
        int w = std::min(midSrcW, endX - curX);
        BlitSprite(targetPixels, targetWidth, targetHeight, curX, 0,
                   glass, midSrcX, 0, w, capH);
        curX += w;
    }
    // Right cap
    BlitSprite(targetPixels, targetWidth, targetHeight, targetWidth - capW, 0,
               glass, glass.width - capW, 0, capW, capH);

    // 2. Bottom Bar: Left (5x20) -> Center stretched -> Right (5x20)
    int botDstY = targetHeight - capH;
    int botSrcY = glass.height - capH; // 20
    // Bottom Left
    BlitSprite(targetPixels, targetWidth, targetHeight, 0, botDstY,
               glass, 0, botSrcY, capW, capH);
    // Bottom Center
    curX = capW;
    while (curX < endX) {
        int w = std::min(midSrcW, endX - curX);
        BlitSprite(targetPixels, targetWidth, targetHeight, curX, botDstY,
                   glass, midSrcX, botSrcY, w, capH);
        curX += w;
    }
    // Bottom Right
    BlitSprite(targetPixels, targetWidth, targetHeight, targetWidth - capW, botDstY,
               glass, glass.width - capW, botSrcY, capW, capH);

    // 3. Middle Left and Right edge bars (if height > 40px)
    if (targetHeight > capH * 2) {
        int midH = targetHeight - capH * 2;
        int midY = capH;
        for (int y = 0; y < midH; ++y) {
            // Sample edge pixels from glass (row 19 and 20)
            for (int x = 0; x < capW; ++x) {
                targetPixels[(midY + y) * targetWidth + x] = glass.GetPixel(x, 19);
                targetPixels[(midY + y) * targetWidth + (targetWidth - capW + x)] = glass.GetPixel(glass.width - capW + x, 19);
            }
        }
    }
}

void GlassRenderer::BlitSprite(uint32_t* dst, int dstW, int dstH, int dstX, int dstY,
                               const RleCodec::Bitmap32& src, int srcX, int srcY, int srcW, int srcH,
                               uint8_t masterAlpha) {
    if (!dst || src.pixels.empty()) return;

    for (int y = 0; y < srcH; ++y) {
        int targetY = dstY + y;
        if (targetY < 0 || targetY >= dstH) continue;

        for (int x = 0; x < srcW; ++x) {
            int targetX = dstX + x;
            if (targetX < 0 || targetX >= dstW) continue;

            uint32_t srcColor = src.GetPixel(srcX + x, srcY + y);
            uint32_t& dstColor = dst[targetY * dstW + targetX];
            dstColor = BlendPixel(dstColor, srcColor, masterAlpha);
        }
    }
}

void GlassRenderer::DrawTimeDigits(uint32_t* dst, int dstW, int dstH, int startX, int y,
                                  const std::string& timeStr, uint8_t alpha) {
    if (m_timeFont.pixels.empty()) return;

    // TIMEFONT: 90x14 total size.
    // Each character is 6px wide, 7px high.
    // Digit offsets: '0'..'9' = 0..9, '-' = 10, ':' = 11, ' ' = 12
    int curX = startX;
    for (char c : timeStr) {
        int charIdx = 12;
        if (c >= '0' && c <= '9') {
            charIdx = c - '0';
        } else if (c == '-') {
            charIdx = 10;
        } else if (c == ':') {
            charIdx = 11;
        }

        int srcX = charIdx * Metrics::TIMEFONT_CHAR_WIDTH;
        BlitSprite(dst, dstW, dstH, curX, y, m_timeFont, srcX, 0,
                   Metrics::TIMEFONT_CHAR_WIDTH, Metrics::TIMEFONT_CHAR_HEIGHT, alpha);
        curX += Metrics::TIMEFONT_CHAR_STEP;
    }
}

void GlassRenderer::DrawGlowText(HDC hdc, const std::wstring& text, const RECT& rc,
                                 COLORREF textColor, COLORREF glowColor, int glowRadius, UINT format) {
    // AirPlay's multi-pass shadow/halo text rendering:
    // 1. Draw blurred halo in 8-direction perimeter passes with glowColor
    // 2. Draw sharp foreground text with textColor
    int oldBkMode = SetBkMode(hdc, TRANSPARENT);

    // Multi-pass glow/halo expansion
    if (glowRadius > 0) {
        SetTextColor(hdc, glowColor);
        for (int dx = -glowRadius; dx <= glowRadius; ++dx) {
            for (int dy = -glowRadius; dy <= glowRadius; ++dy) {
                if (dx == 0 && dy == 0) continue;
                RECT haloRc = rc;
                OffsetRect(&haloRc, dx, dy);
                DrawTextW(hdc, text.c_str(), -1, &haloRc, format);
            }
        }
    }

    // Sharp foreground text
    SetTextColor(hdc, textColor);
    RECT textRc = rc;
    DrawTextW(hdc, text.c_str(), -1, &textRc, format);

    SetBkMode(hdc, oldBkMode);
}

bool GlassRenderer::UpdateLayeredSurface(HWND hwnd, HDC hdcSrc, int x, int y, int w, int h, uint8_t alpha) {
    POINT ptDst = { x, y };
    POINT ptSrc = { 0, 0 };
    SIZE sizeWnd = { w, h };
    BLENDFUNCTION blend = {};
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0;
    blend.SourceConstantAlpha = alpha;
    blend.AlphaFormat = AC_SRC_ALPHA; // 0x01: Per-pixel 32-bit premultiplied ARGB

    return UpdateLayeredWindow(hwnd, nullptr, &ptDst, &sizeWnd, hdcSrc, &ptSrc, 0, &blend, ULW_ALPHA) != FALSE;
}

} // namespace AirPlay

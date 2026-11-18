#pragma once

#include "AirPlayTypes.hpp"
#include "AirPlayRleCodec.hpp"
#include <memory>
#include <string>

namespace AirPlay {

class GlassRenderer {
public:
    GlassRenderer();
    ~GlassRenderer();

    // Initialize renderer with raw RLE or decoded bitmaps
    bool Initialize(const std::wstring& assetDir);

    // Set active window focus state (controls WINDOWGLASS vs WINDOWGLASSFOCUS)
    void SetFocused(bool focused);
    bool IsFocused() const { return m_focused; }

    // Render 9-slice glass border into 32-bit ARGB buffer
    void RenderGlassFrame(uint32_t* targetPixels, int targetWidth, int targetHeight);

    // Blit sprite from atlas with per-pixel alpha blending
    void BlitSprite(uint32_t* dst, int dstW, int dstH, int dstX, int dstY,
                    const RleCodec::Bitmap32& src, int srcX, int srcY, int srcW, int srcH,
                    uint8_t masterAlpha = 255);

    // Draw text with AirPlay's glow halo effect
    void DrawGlowText(HDC hdc, const std::wstring& text, const RECT& rc, 
                      COLORREF textColor, COLORREF glowColor, int glowRadius, UINT format);

    // Blit digit string from TIMEFONT (90x14)
    void DrawTimeDigits(uint32_t* dst, int dstW, int dstH, int startX, int y,
                        const std::string& timeStr, uint8_t alpha = 255);

    // Update Windows layered window from memory DC
    static bool UpdateLayeredSurface(HWND hwnd, HDC hdcSrc, int x, int y, int w, int h, uint8_t alpha = 255);

    // Direct access to assets
    const RleCodec::Bitmap32& GetGlassAsset() const;
    const RleCodec::Bitmap32& GetMiniControl() const { return m_miniControl; }
    const RleCodec::Bitmap32& GetTimeFont() const { return m_timeFont; }
    const RleCodec::Bitmap32& GetWindowButtons() const { return m_windowButton; }

private:
    bool m_focused = true;
    RleCodec::Bitmap32 m_glassNormal;     // WINDOWGLASS (30x40)
    RleCodec::Bitmap32 m_glassFocused;    // WINDOWGLASSFOCUS (30x40)
    RleCodec::Bitmap32 m_miniControl;     // MINICONTROL (96x16)
    RleCodec::Bitmap32 m_miniFont;        // MINIFONT (40x5)
    RleCodec::Bitmap32 m_timeFont;        // TIMEFONT (90x14)
    RleCodec::Bitmap32 m_windowButton;    // WINDOWBUTTON (130x26)
    RleCodec::Bitmap32 m_mainControl;     // MAINCONTROL (192x32)
    RleCodec::Bitmap32 m_hintGlass;       // HINTGLASS (40x40)
};

} // namespace AirPlay

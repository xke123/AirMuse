#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include <string>
#include <vector>

namespace airmuse {

struct LayeredSurface {
    HDC hdcScreen = nullptr;
    HDC hdcMem = nullptr;
    HBITMAP hBmp = nullptr;
    HGDIOBJ oldBmp = nullptr;
    int widthPx = 0;
    int heightPx = 0;

    LayeredSurface() = default;
    ~LayeredSurface();
    LayeredSurface(LayeredSurface const&) = delete;
    LayeredSurface& operator=(LayeredSurface const&) = delete;

    bool Ensure(int wPx, int hPx);
    void Present(HWND hwnd, int wPx, int hPx, BYTE masterAlpha = 255);
    void Release();
};

class GlassRenderer {
public:
    static int ToPx(int dip, int dpi) { return MulDiv(dip, dpi, 96); }
    static int ToDip(int px, int dpi) { return MulDiv(px, 96, dpi); }

    static void EnableFrostedBlur(HWND hwnd, int wPx, int hPx, int dpi, bool mini);
    static std::unique_ptr<Gdiplus::Bitmap> LoadPngResource(HINSTANCE hInst, UINT resId);
    static std::unique_ptr<Gdiplus::Bitmap> DecodeArtworkBitmap(std::vector<uint8_t> const& bytes);

    static void AddRoundedRectPath(Gdiplus::GraphicsPath& path, float x, float y, float w, float h, float r);
    static void DrawAirPlayGlassFrame(Gdiplus::Graphics& g, int dstW, int dstH, float hoverGloss, float focusRatio, Gdiplus::Bitmap* ambientArtwork = nullptr);
    static void DrawAirPlayGlassFrame(Gdiplus::Graphics& g, int dstW, int dstH, float hoverGloss, float focusRatio, Gdiplus::Bitmap* ambientArtwork, bool hasMainGloss);
    static void DrawAirPlayGlassFrame(Gdiplus::Graphics& g, int dstW, int dstH, float hoverGloss, bool focused, Gdiplus::Bitmap* ambientArtwork = nullptr, bool hasMainGloss = false) {
        DrawAirPlayGlassFrame(g, dstW, dstH, hoverGloss, focused ? 1.0f : 0.0f, ambientArtwork, hasMainGloss);
    }
    static void DrawScrollGlassFrame(Gdiplus::Graphics& g, int dstW, int dstH, float scrollProgress, float hoverGloss, float focusRatio, int mode = 1, Gdiplus::Bitmap* ambientArtwork = nullptr);
    static void DrawSpecularSweep(Gdiplus::Graphics& g, int dstW, int dstH, float sweepRatio, float intensity, float sweepRatioX = 0.5f);
    static void DrawImageAlpha(Gdiplus::Graphics& g, Gdiplus::Bitmap* src, Gdiplus::RectF const& dst, int sx, int sy, int sw, int sh, float alpha, float brightness = 1.0f);
    static void DrawTextHalo(Gdiplus::Graphics& g, float cx, float cy, float rx, float ry, BYTE centerAlpha);
    static void DrawBarSpillFog(Gdiplus::Graphics& g, Gdiplus::RectF const& barClip, float anchorX, float leftSpan, float rightSpan, bool fromBottom, BYTE peakAlpha);
    static void DrawPlatformLogo(Gdiplus::Graphics& g, int platformIdx, Gdiplus::RectF const& rect, bool active, float alpha);
    static void DrawGlyphHaloText(Gdiplus::Graphics& g, std::wstring const& text, Gdiplus::FontFamily const& ff, float emSize,
                                  Gdiplus::RectF const& rect, Gdiplus::StringFormat const& sf, Gdiplus::Color textColor, float alphaScale);
    static void DrawCapsuleProgress(Gdiplus::Graphics& g, Gdiplus::RectF const& r, float ratio, bool highlight, bool scrubbing, std::wstring const& scrubTimeText);
};

} // namespace airmuse
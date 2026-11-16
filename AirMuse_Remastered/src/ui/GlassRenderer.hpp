#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include <string>
#include <vector>

namespace airmuse {

class GlassRenderer {
public:
    static int ToPx(int dip, int dpi) { return MulDiv(dip, dpi, 96); }
    static int ToDip(int px, int dpi) { return MulDiv(px, 96, dpi); }

    static void EnableFrostedBlur(HWND hwnd, int wPx, int hPx, int dpi, bool mini);
    static std::unique_ptr<Gdiplus::Bitmap> LoadPngResource(HINSTANCE hInst, UINT resId);
    static std::unique_ptr<Gdiplus::Bitmap> DecodeArtworkBitmap(std::vector<uint8_t> const& bytes);

    static void AddRoundedRectPath(Gdiplus::GraphicsPath& path, float x, float y, float w, float h, float r);
    static void DrawAirPlayGlassFrame(Gdiplus::Graphics& g, int dstW, int dstH, float hoverGloss, bool focused, Gdiplus::Bitmap* ambientArtwork = nullptr);
    static void DrawImageAlpha(Gdiplus::Graphics& g, Gdiplus::Bitmap* src, Gdiplus::RectF const& dst, int sx, int sy, int sw, int sh, float alpha, float brightness = 1.0f);
    static void DrawTextHalo(Gdiplus::Graphics& g, float cx, float cy, float rx, float ry, BYTE centerAlpha);

    // 支持左右非对称延伸（黄金分割线方向性）+ 垂直梯形溢流的玻璃条暗雾
    static void DrawBarSpillFog(Gdiplus::Graphics& g, Gdiplus::RectF const& barClip, float anchorX, float leftSpan, float rightSpan, bool fromBottom, BYTE peakAlpha);

    // 绘制微型平台矢量 Logo (0: Apple Music, 1: Spotify, 2: QQ音乐)
    static void DrawPlatformLogo(Gdiplus::Graphics& g, int platformIdx, Gdiplus::RectF const& rect, bool active, float alpha);

    static void DrawGlyphHaloText(Gdiplus::Graphics& g, std::wstring const& text, Gdiplus::FontFamily const& ff, float emSize,
                                  Gdiplus::RectF const& rect, Gdiplus::StringFormat const& sf, Gdiplus::Color textColor, float alphaScale);
    static void DrawCapsuleProgress(Gdiplus::Graphics& g, Gdiplus::RectF const& r, float ratio, bool highlight, bool scrubbing, std::wstring const& scrubTimeText);
};

} // namespace airmuse



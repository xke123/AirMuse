#include "presentation/rendering/PlayerRenderer.hpp"
#ifdef _WIN32
#include <objidl.h>
#include <algorithm>
#include <memory>
#include <string>
#include <utility>

using namespace Gdiplus;

namespace airmuse {
namespace {
std::unique_ptr<Bitmap> LoadBitmapFile(const wchar_t* name) {
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    auto slash = wcsrchr(path, L'\\');
    if (slash) *(slash + 1) = 0;
    wcscat_s(path, L"resources\\ui\\");
    wcscat_s(path, name);
    auto bitmap = std::make_unique<Bitmap>(path);
    return bitmap->GetLastStatus() == Ok ? std::move(bitmap) : nullptr;
}

void DrawSprite(Graphics& g, Bitmap* bitmap, Rect destination, int frame, int frameSize, float alpha) {
    if (!bitmap || alpha <= 0.0f) return;
    ColorMatrix matrix = {{
        {1, 0, 0, 0, 0}, {0, 1, 0, 0, 0}, {0, 0, 1, 0, 0},
        {0, 0, 0, alpha, 0}, {0, 0, 0, 0, 1}
    }};
    ImageAttributes attributes;
    attributes.SetColorMatrix(&matrix);
    g.DrawImage(bitmap, destination, frame * frameSize, 0, frameSize, frameSize, UnitPixel, &attributes);
}

Rect ButtonRect(const PlayerVisualState& state, int index) {
    const int width = state.width;
    if (state.compact) {
        const int start = (width - 92) / 2;
        const int positions[] = {start, start + 18, start + 37, start + 56, start + 74};
        if (index >= 0 && index < 5) return {positions[index], 5, 16, 16};
        if (index == 6) return {width - 36, 6, 13, 13};
        if (index == 8) return {width - 20, 6, 13, 13};
    } else {
        const int start = (width - 166) / 2;
        const int positions[] = {start, start + 32, start + 67, start + 102, start + 134};
        if (index >= 0 && index < 5) return {positions[index], 26, 32, 32};
        if (index == 5) return {width - 66, 4, 13, 13};
        if (index == 6) return {width - 50, 4, 13, 13};
        if (index == 7) return {width - 34, 4, 13, 13};
        if (index == 8) return {width - 18, 4, 13, 13};
        if (index == 9) return {68, 63, width - 136, 14};
        if (index == 11) return {width - 28, state.height - 17, 13, 13};
    }
    return {};
}

void FillRounded(Graphics& g, float x, float y, float width, float height, float radius, Color color) {
    GraphicsPath path;
    const float diameter = radius * 2.0f;
    path.AddArc(x, y, diameter, diameter, 180, 90);
    path.AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
    path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
    path.AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
    SolidBrush brush(color);
    g.FillPath(&brush, &path);
}

std::wstring FormatTime(long long milliseconds) {
    wchar_t buffer[24]{};
    swprintf_s(buffer, L"%02lld:%02lld", milliseconds / 60000, (milliseconds / 1000) % 60);
    return buffer;
}
}

PlayerRenderer::PlayerRenderer() = default;
PlayerRenderer::~PlayerRenderer() = default;

void PlayerRenderer::Load() {
    main_ = LoadBitmapFile(L"MAINCONTROL.png");
    mini_ = LoadBitmapFile(L"MINICONTROL.png");
    buttons_ = LoadBitmapFile(L"WINDOWBUTTON.png");
}

void PlayerRenderer::Draw(HDC dc, const PlayerVisualState& state) {
    Graphics graphics(dc);
    graphics.ScaleTransform(static_cast<float>(state.dpi) / 96.0f, static_cast<float>(state.dpi) / 96.0f);
    graphics.SetSmoothingMode(SmoothingModeHighQuality);
    graphics.SetTextRenderingHint(TextRenderingHintAntiAlias);
    FillRounded(graphics, 2, 2, static_cast<float>(state.width - 4), static_cast<float>(state.height - 4),
                state.compact ? 5.0f : 9.0f, Color(232, 29, 31, 36));

    FontFamily fontFamily(L"Segoe UI");
    StringFormat centered;
    centered.SetAlignment(StringAlignmentCenter);
    centered.SetTrimming(StringTrimmingEllipsisCharacter);

    if (state.compact) {
        std::wstring title(state.media.title.begin(), state.media.title.end());
        Font font(&fontFamily, 11, FontStyleRegular, UnitPixel);
        SolidBrush text(Color(245, 245, 247, 250));
        graphics.DrawString(title.c_str(), -1, &font, RectF(12, 4, static_cast<REAL>(state.width - 24), 18), &centered, &text);
        if (state.hover > 0.01f) {
            const int playFrame = state.media.status == PlaybackStatus::Playing ? 3 : 2;
            DrawSprite(graphics, mini_.get(), ButtonRect(state, 2), playFrame, 64, state.hover);
            DrawSprite(graphics, mini_.get(), ButtonRect(state, 1), 1, 64, state.hover);
            DrawSprite(graphics, mini_.get(), ButtonRect(state, 3), 4, 64, state.hover);
            DrawSprite(graphics, buttons_.get(), ButtonRect(state, 6), 4, 52, state.hover);
            DrawSprite(graphics, buttons_.get(), ButtonRect(state, 8), 2, 52, state.hover);
        }
        return;
    }

    Font titleFont(&fontFamily, 13, FontStyleBold, UnitPixel);
    Font artistFont(&fontFamily, 11, FontStyleRegular, UnitPixel);
    Font timeFont(&fontFamily, 9, FontStyleRegular, UnitPixel);
    SolidBrush titleBrush(Color(248, 245, 247, 250));
    SolidBrush artistBrush(Color(205, 196, 203, 214));
    SolidBrush timeBrush(Color(210, 195, 205, 218));
    const std::wstring title(state.media.title.begin(), state.media.title.end());
    const std::wstring artist(state.media.artist.begin(), state.media.artist.end());
    graphics.DrawString(title.c_str(), -1, &titleFont, RectF(32, 22, static_cast<REAL>(state.width - 64), 19), &centered, &titleBrush);
    graphics.DrawString(artist.c_str(), -1, &artistFont, RectF(32, 41, static_cast<REAL>(state.width - 64), 17), &centered, &artistBrush);

    const auto duration = state.media.duration.count();
    const auto position = std::chrono::duration_cast<Milliseconds>(state.media.position).count();
    const float ratio = duration > 0 ? std::clamp(static_cast<float>(position) / static_cast<float>(duration), 0.0f, 1.0f) : 0.0f;
    FillRounded(graphics, 68, 67, static_cast<float>(state.width - 136), 5, 3, Color(140, 15, 17, 21));
    if (ratio > 0.0f) FillRounded(graphics, 68, 67, std::max(5.0f, static_cast<float>(state.width - 136) * ratio), 5, 3, Color(225, 139, 196, 237));
    const auto positionText = FormatTime(position);
    const auto durationText = FormatTime(duration);
    graphics.DrawString(positionText.c_str(), -1, &timeFont, RectF(24, 64, 40, 14), nullptr, &timeBrush);
    graphics.DrawString(durationText.c_str(), -1, &timeFont, RectF(static_cast<REAL>(state.width - 64), 64, 40, 14), nullptr, &timeBrush);

    if (state.hover <= 0.01f) return;
    const int playFrame = state.media.status == PlaybackStatus::Playing ? 3 : 2;
    const int buttonFrames[] = {0, 1, playFrame, 4, 5};
    for (int index = 0; index < 5; ++index) {
        const float alpha = state.hover * (state.hovered == index ? 1.0f : 0.78f);
        DrawSprite(graphics, main_.get(), ButtonRect(state, index), buttonFrames[index], 128, alpha);
    }
    const int windowButtons[][2] = {{5, 0}, {6, 7}, {7, 6}, {8, 2}};
    for (const auto& button : windowButtons) {
        DrawSprite(graphics, buttons_.get(), ButtonRect(state, button[0]), button[1], 52,
                   state.hover * (state.hovered == button[0] ? 1.0f : 0.72f));
    }
    DrawSprite(graphics, buttons_.get(), ButtonRect(state, 11), 8, 52, state.hover * 0.85f);
}
}
#endif

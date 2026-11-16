#pragma once
#include "../core/WinCommon.hpp"
#include <functional>
#include "SpringAnimator.hpp"

namespace airmuse {

struct UIButton {
    int id = 0;
    Gdiplus::RectF bounds{};
    bool visible = true;
    bool enabled = true;
    bool hitCircle = false;

    SpringValue hoverAnim{ 0.0f, 0.0f, 0.0f, 320.0f, 26.0f };
    SpringValue pressAnim{ 1.0f, 1.0f, 0.0f, 450.0f, 28.0f };

    std::function<void()> onClick;

    bool HitTest(float xDip, float yDip) const {
        if (!visible || !enabled) return false;
        if (hitCircle) {
            float cx = bounds.X + bounds.Width * 0.5f;
            float cy = bounds.Y + bounds.Height * 0.5f;
            float r  = bounds.Width * 0.5f;
            float dx = xDip - cx, dy = yDip - cy;
            return (dx * dx + dy * dy) <= (r * r);
        }
        return bounds.Contains(xDip, yDip);
    }

    bool UpdatePhysics(float dt) {
        bool a = hoverAnim.Step(dt);
        bool b = pressAnim.Step(dt);
        return a || b;
    }
};

} // namespace airmuse

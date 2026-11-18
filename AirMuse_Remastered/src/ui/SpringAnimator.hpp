#pragma once
#include <cmath>
#include <algorithm>

namespace airmuse {

struct SpringConfig {
    float stiffness = 260.0f;
    float damping   = 24.0f;
};

namespace MotionPreset {
    // 瞬态快速反馈：按钮悬停、点击下压、开关切换 (高频响应，轻微回弹)
    inline constexpr SpringConfig Snappy{ 340.0f, 26.0f };
    // 弹性質感：弹窗弹出、卡片缩放、角标跳动 (较强弹力，生动活泼)
    inline constexpr SpringConfig Bouncy{ 220.0f, 18.0f };
    // 平滑位移：文本跑马灯轮播、歌词逐行滚动、滑块拖拽跟随 (临界阻尼，丝滑平稳)
    inline constexpr SpringConfig Smooth{ 260.0f, 32.0f };
    // 氛围漫延：焦点切换、毛玻璃光晕呼吸、背景遮罩淡入淡出 (柔和舒缓，静谧优雅)
    inline constexpr SpringConfig Gentle{ 160.0f, 24.0f };
}

struct SpringValue {
    float current   = 0.0f;
    float target    = 0.0f;
    float velocity  = 0.0f;
    float stiffness = 260.0f;
    float damping   = 24.0f;

    SpringValue() = default;
    SpringValue(float initialVal, SpringConfig const& cfg = MotionPreset::Smooth)
        : current(initialVal), target(initialVal), velocity(0.0f), stiffness(cfg.stiffness), damping(cfg.damping) {}
    SpringValue(float initialVal, float targetVal, float vel, float stiff, float damp)
        : current(initialVal), target(targetVal), velocity(vel), stiffness(stiff), damping(damp) {}

    void SetConfig(SpringConfig const& cfg) {
        stiffness = cfg.stiffness;
        damping   = cfg.damping;
    }

    void SetTarget(float val) {
        target = val;
    }

    void SnapTo(float val) {
        current = target = val;
        velocity = 0.0f;
    }

    bool IsSettled(float eps = 0.002f) const {
        return std::abs(current - target) < eps && std::abs(velocity) < eps;
    }

    bool Step(float dtSeconds) {
        if (dtSeconds > 0.05f) dtSeconds = 0.05f;
        float displacement = current - target;
        if (std::abs(displacement) < 0.002f && std::abs(velocity) < 0.002f) {
            current = target;
            velocity = 0.0f;
            return false;
        }
        float force = -stiffness * displacement - damping * velocity;
        velocity += force * dtSeconds;
        current  += velocity * dtSeconds;
        return true;
    }

    operator float() const { return current; }
};

} // namespace airmuse

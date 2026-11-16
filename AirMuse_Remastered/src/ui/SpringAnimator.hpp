#pragma once
#include <cmath>

namespace airmuse {

struct SpringValue {
    float current  = 0.0f;
    float target   = 0.0f;
    float velocity = 0.0f;
    float stiffness = 260.0f;
    float damping   = 22.0f;

    void SnapTo(float val) {
        current = target = val;
        velocity = 0.0f;
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
};

} // namespace airmuse
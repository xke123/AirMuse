#include "MotionCoordinator.hpp"

namespace airmuse {

MotionCoordinator& MotionCoordinator::Instance() {
    static MotionCoordinator s_inst;
    return s_inst;
}

void MotionCoordinator::AttachHost(HWND hostHwnd) {
    m_hostHwnd = hostHwnd;
    if (m_running && m_hostHwnd) {
        SetTimer(m_hostHwnd, TIMER_MOTION_VSYNC, 16, nullptr);
    }
}

void MotionCoordinator::DetachHost(HWND hostHwnd) {
    if (m_hostHwnd == hostHwnd) {
        if (m_running && m_hostHwnd) {
            KillTimer(m_hostHwnd, TIMER_MOTION_VSYNC);
        }
        m_hostHwnd = nullptr;
    }
}

void MotionCoordinator::RegisterClient(IMotionClient* client) {
    if (!client) return;
    auto it = std::find(m_clients.begin(), m_clients.end(), client);
    if (it == m_clients.end()) {
        m_clients.push_back(client);
    }
}

void MotionCoordinator::UnregisterClient(IMotionClient* client) {
    auto it = std::find(m_clients.begin(), m_clients.end(), client);
    if (it != m_clients.end()) {
        m_clients.erase(it);
    }
}

void MotionCoordinator::RequestFrame() {
    if (!m_running) {
        m_running = true;
        m_lastTick = GetTickCount64();
        if (m_hostHwnd) {
            SetTimer(m_hostHwnd, TIMER_MOTION_VSYNC, 16, nullptr);
        }
    }
}

void MotionCoordinator::OnTick() {
    if (!m_running) return;

    ULONGLONG now = GetTickCount64();
    float dt = static_cast<float>(now - m_lastTick) / 1000.0f;
    if (dt <= 0.001f) dt = 0.016f;
    if (dt > 0.05f) dt = 0.05f;
    m_lastTick = now;

    bool anyActive = false;
    for (auto* client : m_clients) {
        if (client) {
            bool active = client->StepMotion(dt);
            if (active) {
                anyActive = true;
                client->OnMotionRender();
            }
        }
    }

    if (!anyActive) {
        m_running = false;
        if (m_hostHwnd) {
            KillTimer(m_hostHwnd, TIMER_MOTION_VSYNC);
        }
    }
}

} // namespace airmuse

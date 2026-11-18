#pragma once
#include "../core/WinCommon.hpp"
#include <vector>
#include <algorithm>

namespace airmuse {

constexpr UINT_PTR TIMER_MOTION_VSYNC = 0xA11;

class IMotionClient {
public:
    virtual ~IMotionClient() = default;
    // Advance physics by dt (seconds). Return true if this client has active animating springs.
    virtual bool StepMotion(float dt) = 0;
    // Called when the frame has finished stepping and repainting is needed.
    virtual void OnMotionRender() = 0;
};

class MotionCoordinator {
public:
    static MotionCoordinator& Instance();

    void AttachHost(HWND hostHwnd);
    void DetachHost(HWND hostHwnd);

    void RegisterClient(IMotionClient* client);
    void UnregisterClient(IMotionClient* client);

    void RequestFrame();
    void OnTick();

    bool IsRunning() const { return m_running; }

private:
    MotionCoordinator() = default;
    ~MotionCoordinator() = default;
    MotionCoordinator(MotionCoordinator const&) = delete;
    MotionCoordinator& operator=(MotionCoordinator const&) = delete;

    HWND m_hostHwnd = nullptr;
    std::vector<IMotionClient*> m_clients;
    bool m_running = false;
    ULONGLONG m_lastTick = 0;
};

} // namespace airmuse

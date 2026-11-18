#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include <vector>
#include "../core/AppController.hpp"
#include "SpringAnimator.hpp"
#include "UIElement.hpp"
#include "DockManager.hpp"
#include "GlassRenderer.hpp"
#include "MotionCoordinator.hpp"

namespace airmuse {

enum class AnimSpeed {
    Speed1_5s,
    Speed2_0s
};

class TestPanelWindow : public IMotionClient {
public:
    static constexpr int DEFAULT_WIDTH_DIP  = 330;
    static constexpr int DEFAULT_HEIGHT_DIP = 106;

    TestPanelWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~TestPanelWindow() override;

    HWND Create(HWND parentMain);
    HWND Hwnd() const { return m_hwnd; }

    void SetEffect(int effectId) { m_currentEffect = effectId; }
    int  GetEffect() const { return m_currentEffect; }

    void SetAnimSpeed(AnimSpeed speed);
    void ToggleAnimSpeed();
    AnimSpeed GetAnimSpeed() const { return m_animSpeed; }
    float GetAnimDuration() const { return m_animDuration; }

    void Unroll(int effectId = 1);
    void Rollup(int effectId = 1);
    void SyncPositionWithMain(bool ensureOnScreen = false);
    bool IsRolledUp() const { return m_animTarget <= 0.01f && m_animProgress <= 0.01f; }
    bool IsUnrolled() const { return m_animTarget >= 0.99f && m_animProgress >= 0.99f; }

    void Render();

    // IMotionClient
    bool StepMotion(float dt) override;
    void OnMotionRender() override;

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

    void BuildUIElements();
    void UpdateLayout(float animT);
    UIButton* FindBtn(int id);

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    HWND m_hwnd = nullptr;
    HWND m_parentMain = nullptr;
    int m_dpi = 96;

    int m_currentEffect = 1;
    bool m_focused = true;
    bool m_hovering = false;

    // 时间驱动动画参数：实现精准可调的 1.5s 与 2.0s 细腻四阶段展开/收起
    AnimSpeed m_animSpeed = AnimSpeed::Speed1_5s;
    float m_animDuration = 1.5f;
    float m_animTime = 0.0f;
    float m_animTarget = 0.0f;
    float m_animProgress = 0.0f;

    SpringValue m_focusAnim{ 1.0f, MotionPreset::Gentle };
    SpringValue m_hoverGloss{ 0.0f, MotionPreset::Snappy };

    std::vector<UIButton> m_buttons;
    int m_hoverBtnId = -1;
    int m_pressedBtnId = -1;

    LayeredSurface m_surface;

    std::unique_ptr<Gdiplus::Bitmap> m_mainCtrlBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_artworkBmp;
    std::wstring m_cachedArtKey;
};

} // namespace airmuse

# AirMuse Motion V2 — 原生材质与光学效果规范

目标：原始水晶外框承担辨识度，Liquid Glass仅承担动态控件材质。不是全窗磨砂，不是以CSS式模糊冒充系统玻璃。

## SDK能力验证门槛
现有 Package.swift 声明 macOS 26，当前源码已使用 NSGlassEffectView。先运行 `xcrun --show-sdk-path`、检查本地 AppKit/SwiftUI 公共接口并构建最小验证目标。不得假设所有SwiftUI交互修饰符在Mac上有iOS同等行为。
| 能力 | 优先实现 | 验证与降级 |
|---|---|---|
| 局部材质 | NSGlassEffectView .clear | 原生材质在透明宿主、复杂壁纸及不同焦点下真实可见；失败回退原精灵 |
| 玻璃组合 | NSGlassEffectContainerView（验证SDK） | 实测邻近玻璃组合效果与裁切；无融合则共享玻璃背景+CA几何，不宣称原生融合 |
| 身份形变 | 可选局部NSHostingView + GlassEffectContainer/glassEffectID/glassEffectTransition | 仅在AppKit不足且真机证明收益时使用；禁止全App SwiftUI迁移 |
| 交互高光 | 原生材质能力+轻量CALayer | 不使用私有shader、私有窗口接口或桌面屏幕抓取模拟折射 |
| 触觉 | NSHapticFeedbackManager .alignment | 仅支持设备且吸附成功时触发；无设备则静默 |

## 实验矩阵（进入生产前完成）
A. 在普通/Mini播放按钮测试材质透明度、鼠标命中、原图标对比；B. 共享控制容器测试邻近元素靠近与分开；C. 进度滑块在drag时改变几何，浮层跟随且不抢焦点；D. 音量/菜单胶囊展开，验证Esc和点击外部；E. 浅/深/高频壁纸及系统减少透明度；F. 120Hz及多屏切换。记录实际API、SDK版本、录像、性能开销与失败案例。每项未实测保持PENDING_INTEGRATION。

## 视觉分层
1. OriginalGlassRenderer绘制原始边缘与精灵；不得叠加不透明黑底破坏Mini水晶条。
2. 局部Glass容器置于内容或交互层，保持控件轮廓、裁切边界、命中区域和可访问性。背景装饰不截获事件。
3. 图标、文字、紧凑光晕置于可读前景；不对文字应用整体模糊，不用过强光晕。
4. Specular宏观扫光与微观高光共享预算，最多2条宏观扫光；减少动态效果、隐藏或离屏时取消；禁止持续装饰呼吸。
5. Aurora环境光限制在原定光雾区域，封面颜色缓存；不能染满原始边框。

## 关键落地
M03/04/05：共享玻璃背景或经验证的容器，高光在控制之间连续移动，按压保持原版1pt物理反馈。M09/10：滑块局部增强、时间和音量提示，拖动跟手。M19：同一视图层内连续展开；容器融合失败用原生菜单或局部几何过渡。M02/13/14：外框仍由原皮肤分片组合，不强求整窗Liquid Glass形变。M12/24：触觉与手势仅是增强，不成为功能前提。

## 官方参考（实施前核实当前文档及SDK）
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager
- https://developer.apple.com/documentation/quartzcore/caspringanimation

上述链接是待核实的API参考入口，不代表本包已完成SDK实验。遇到能力限制记录具体编译错误和降级路径，不阻塞其余功能。

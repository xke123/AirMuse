#pragma once
#ifdef _WIN32
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>
#include <memory>
#include "core/domain/MediaSnapshot.hpp"
namespace airmuse {
struct PlayerVisualState { int width{320},height{104}; int dpi{96}; float hover{}; int hovered{-1},pressed{-1}; bool compact{}; bool alwaysOnTop{true}; MediaSnapshot media; };
class PlayerRenderer { public: PlayerRenderer(); ~PlayerRenderer(); void Load(); void Draw(HDC,const PlayerVisualState&); private: std::unique_ptr<Gdiplus::Bitmap> main_,mini_,buttons_; };
}
#endif

#pragma once
#ifdef _WIN32
#include <windows.h>
#include "app/Application.hpp"
#include "presentation/rendering/PlayerRenderer.hpp"
namespace airmuse { class FloatingWindow { public: explicit FloatingWindow(Application&); int Run(HINSTANCE); private: static LRESULT CALLBACK Proc(HWND,UINT,WPARAM,LPARAM); LRESULT Handle(HWND,UINT,WPARAM,LPARAM); int HitTest(int,int)const; Application& app_;HWND hwnd_{};PlayerRenderer renderer_;int dpi_{96},hovered_{-1},pressed_{-1};float hover_{};bool hovering_{},tracking_{},compact_{}; }; }
#endif

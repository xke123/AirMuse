#include "presentation/windows/FloatingWindow.hpp"
#ifdef _WIN32
#include <gdiplus.h>
#include <windowsx.h>
namespace airmuse {
namespace { constexpr int CompactH=28,ExpandedH=104; constexpr int W=320; }
FloatingWindow::FloatingWindow(Application&a):app_(a){}
int FloatingWindow::Run(HINSTANCE instance){
 Gdiplus::GdiplusStartupInput input;ULONG_PTR token{};Gdiplus::GdiplusStartup(&token,&input,nullptr);
 WNDCLASSW wc{};wc.hInstance=instance;wc.lpfnWndProc=Proc;wc.lpszClassName=L"AirMuse.Refactored";wc.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassW(&wc);
 hwnd_=CreateWindowExW(WS_EX_LAYERED|WS_EX_TOPMOST|WS_EX_TOOLWINDOW,L"AirMuse.Refactored",L"AirMuse",WS_POPUP|WS_VISIBLE,100,100,W,ExpandedH,nullptr,nullptr,instance,this);
 MSG m;while(GetMessageW(&m,nullptr,0,0)>0){TranslateMessage(&m);DispatchMessageW(&m);}Gdiplus::GdiplusShutdown(token);return(int)m.wParam;
}
LRESULT CALLBACK FloatingWindow::Proc(HWND h,UINT m,WPARAM w,LPARAM l){auto*self=reinterpret_cast<FloatingWindow*>(GetWindowLongPtrW(h,GWLP_USERDATA));if(m==WM_NCCREATE){self=static_cast<FloatingWindow*>((reinterpret_cast<CREATESTRUCTW*>(l))->lpCreateParams);SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}return self?self->Handle(h,m,w,l):DefWindowProcW(h,m,w,l);}
LRESULT FloatingWindow::Handle(HWND h,UINT msg,WPARAM w,LPARAM l){
 switch(msg){
 case WM_CREATE: renderer_.Load();dpi_=GetDpiForWindow(h);SetTimer(h,1,16,nullptr);SetTimer(h,2,1000,nullptr);return 0;
 case WM_TIMER: if(w==1){float target=hovering_?1.f:0.f;if(hover_<target)hover_=std::min(target,hover_+.12f);else if(hover_>target)hover_=std::max(target,hover_-.12f);InvalidateRect(h,nullptr,FALSE);}else{if(auto active=app_.Playback().Active();active&&active->status==PlaybackStatus::Playing){active->position+=Milliseconds(1000);active->updatedAt=std::chrono::steady_clock::now();}InvalidateRect(h,nullptr,FALSE);}return 0;
 case WM_MOUSEMOVE:{if(!tracking_){TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0};TrackMouseEvent(&t);tracking_=true;}hovering_=true;int old=hovered_;hovered_=HitTest(GET_X_LPARAM(l),GET_Y_LPARAM(l));if(old!=hovered_)InvalidateRect(h,nullptr,FALSE);return 0;}
 case WM_MOUSELEAVE:tracking_=false;hovering_=false;hovered_=-1;return 0;
 case WM_LBUTTONDOWN:SetCapture(h);pressed_=HitTest(GET_X_LPARAM(l),GET_Y_LPARAM(l));InvalidateRect(h,nullptr,FALSE);return 0;
 case WM_LBUTTONUP:{ReleaseCapture();int hit=HitTest(GET_X_LPARAM(l),GET_Y_LPARAM(l));int pressed=pressed_;pressed_=-1;InvalidateRect(h,nullptr,FALSE);if(hit!=pressed)return 0;auto s=app_.Playback().Active();if(hit==2)app_.TogglePlayback();else if(hit==1)app_.Playback().Dispatch(PlaybackCommand::Previous);else if(hit==3)app_.Playback().Dispatch(PlaybackCommand::Next);else if(hit==6){compact_=!compact_;SetWindowPos(h,nullptr,0,0,0,compact_?CompactH:ExpandedH,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);}else if(hit==8)DestroyWindow(h);else if(hit==9&&s){int x=GET_X_LPARAM(l)*96/dpi_;auto pos=Milliseconds(std::max(0,x-68)*s->duration.count()/std::max(1,W-136));app_.Playback().Seek(pos);}return 0;}
 case WM_RBUTTONUP:compact_=!compact_;SetWindowPos(h,nullptr,0,0,0,compact_?CompactH:ExpandedH,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);return 0;
 case WM_DPICHANGED:dpi_=HIWORD(w);return 0;
 case WM_PAINT:{PAINTSTRUCT ps;auto dc=BeginPaint(h,&ps);PlayerVisualState state;state.width=W;state.height=compact_?CompactH:ExpandedH;state.dpi=dpi_;state.hover=hover_;state.hovered=hovered_;state.pressed=pressed_;state.compact=compact_;if(auto s=app_.Playback().Active())state.media=*s;renderer_.Draw(dc,state);EndPaint(h,&ps);return 0;}
 case WM_DESTROY:KillTimer(h,1);KillTimer(h,2);PostQuitMessage(0);return 0;
 }
 return DefWindowProcW(h,msg,w,l);
}
int FloatingWindow::HitTest(int px,int py)const{int x=px*96/dpi_,y=py*96/dpi_;if(compact_){if(y<0||y>28)return -1;if(x>W-45&&x<W-28)return 6;if(x>W-26)return 8;int center=W/2;if(x>center-12&&x<center+12)return 2;if(x<center-12&&x>center-37)return 1;if(x>center+12&&x<center+37)return 3;return -1;}if(y>=63&&y<=78&&x>=68&&x<=W-68)return 9;if(y>=26&&y<=58){int start=(W-166)/2;int xs[]={start,start+32,start+67,start+102,start+134};for(int i=0;i<5;++i)if(x>=xs[i]&&x<xs[i]+32)return i;}if(y<20&&x>W-60&&x<W-40)return 6;if(y<20&&x>W-24)return 8;return -1;}
}
#endif

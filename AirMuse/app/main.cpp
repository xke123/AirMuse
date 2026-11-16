#include "app/Application.hpp"
#include "presentation/windows/FloatingWindow.hpp"
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE, PWSTR,int){airmuse::Application app;if(!app.Start())return 1;return airmuse::FloatingWindow(app).Run(instance);}

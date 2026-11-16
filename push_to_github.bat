@echo off
chcp 65001 >nul
echo ========================================================
echo   AirMuse - Push to GitHub (https://github.com/xke123/AirMuse.git)
echo ========================================================
echo.
cd /d "%~dp0"

echo [1/3] 检查并配置代理...
git config http.proxy http://127.0.0.1:7897
git config https.proxy http://127.0.0.1:7897

echo [2/3] 检查本地仓库状态...
git status

echo.
echo [3/3] 正在推送到 GitHub 远程仓库 (首次推送可能会弹出 GitHub 网页授权登录窗口)...
git push -u origin main

if %ERRORLEVEL% equ 0 (
    echo.
    echo ========================================================
    echo   [SUCCESS] 项目已成功推送到 https://github.com/xke123/AirMuse.git !
    echo ========================================================
) else (
    echo.
    echo ========================================================
    echo   [FAILED] 推送未完成，请检查是否已在浏览器中完成 GitHub 授权，
    echo   或者提供 Personal Access Token (PAT)。
    echo ========================================================
)

echo.
pause

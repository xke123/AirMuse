# run.ps1
Set-Location $PSScriptRoot

# 1. 优先立即终止当前可能正在运行的 AirMuse 实例，确保后续编译写入与运行不被文件占用
Get-Process -Name "AirMuse*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

$vsRoot = "E:\Soft\Dependency\VS2022BuildTools"
$vcVars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"
if (Test-Path $vcVars) {
    $tempBat = Join-Path $env:TEMP "airmuse_env_$PID.bat"
    "@echo off`r`ncall `"$vcVars`" >nul 2>&1`r`nset" | Set-Content -Path $tempBat -Encoding ASCII
    cmd /c "`"$tempBat`"" | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        }
    }
    Remove-Item -Path $tempBat -Force -ErrorAction SilentlyContinue
}
$cmake = Join-Path $vsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
if (-not (Test-Path $cmake)) {
    $cmake = "cmake"
}

# 自动打包组合前端组件化脚本 (UI Core + AppleMusicProvider -> airmuse_apple_engine.js)
if (Test-Path "src\media\bundle.js") {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        node "src\media\bundle.js"
    } else {
        $uiCore = Get-Content "src\media\airmuse_ui_core.js" -Raw -Encoding UTF8
        $appleProvider = Get-Content "src\media\provider\apple_music_provider.js" -Raw -Encoding UTF8
        $bundleHeader = "// airmuse_apple_engine.js`n(function () { function ensureAppMounted() { try { if (window.AirMuseUI && window.AirMuseUI.dom && window.AirMuseUI.dom.appRoot && document.body && !document.body.contains(window.AirMuseUI.dom.appRoot)) { document.body.appendChild(window.AirMuseUI.dom.appRoot); } } catch (_) {} } if (window.__airmuseEngineInited) { ensureAppMounted(); return; } function bootstrap() { if (!document.body) { if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', bootstrap, { once: true }); } else { setTimeout(bootstrap, 50); } return; } if (window.__airmuseEngineInited) { ensureAppMounted(); return; } window.__airmuseEngineInited = true; try {"
        $bundleFooter = "const provider = new window.AppleMusicProvider(); window.AirMuseUI.init(provider); } catch (err) { console.error('[AirMuse] bootstrap error:', err); } } bootstrap(); })();"
        Set-Content -Path "src\media\airmuse_apple_engine.js" -Value ($bundleHeader + "`n" + $uiCore + "`n" + $appleProvider + "`n" + $bundleFooter) -Encoding UTF8
    }
}

# 如果没有 build 目录或 CMake 未生成工程，先自动执行 configure
if (-not (Test-Path "build\CMakeCache.txt")) {
    & $cmake -B build -G "Visual Studio 17 2022" -A x64
}

# 编译
& $cmake --build build --config Release --parallel
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[SUCCESS] 编译成功，正在启动 AirMuse..." -ForegroundColor Green
    $exePath = if (Test-Path (Join-Path $PSScriptRoot "build\Release\AirMuse.exe")) {
        Join-Path $PSScriptRoot "build\Release\AirMuse.exe"
    } else {
        Join-Path $PSScriptRoot "build\AirMuse.exe"
    }
    # 确保无论 C++ 是否重编，最新的前端脚本都同步到可执行文件所在目录
    Copy-Item -Path (Join-Path $PSScriptRoot "src\media\airmuse_apple_engine.js") -Destination (Split-Path $exePath) -Force
    Start-Process -FilePath $exePath -WorkingDirectory $PSScriptRoot
} else {
    Write-Host "`n[FAILED] 编译失败，请检查报错！" -ForegroundColor Red
}

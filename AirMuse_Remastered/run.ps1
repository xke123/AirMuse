# run.ps1
Set-Location $PSScriptRoot

$vsRoot = "E:\Soft\Dependency\VS2022BuildTools"
$vcVars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$vcVars`" >nul && set" | ForEach-Object {
    if ($_ -match "^([^=]+)=(.*)$") {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}
$cmake = Join-Path $vsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

# 终止可能已在运行的实例，避免写入文件被占用
Stop-Process -Name AirMuse -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600

# 自动打包组合前端组件化脚本 (UI Core + AppleMusicProvider -> airmuse_apple_engine.js)
if (Test-Path "src\media\bundle.js") {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        node "src\media\bundle.js"
    } else {
        $uiCore = Get-Content "src\media\airmuse_ui_core.js" -Raw -Encoding UTF8
        $appleProvider = Get-Content "src\media\provider\apple_music_provider.js" -Raw -Encoding UTF8
        $bundleHeader = "// airmuse_apple_engine.js`n(function () { if (window.__airmuseEngineInited) return; function bootstrap() { if (!document.body) { if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', bootstrap, { once: true }); } else { setTimeout(bootstrap, 50); } return; } if (window.__airmuseEngineInited) return; window.__airmuseEngineInited = true;"
        $bundleFooter = "const provider = new window.AppleMusicProvider(); window.AirMuseUI.init(provider); } bootstrap(); })();"
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

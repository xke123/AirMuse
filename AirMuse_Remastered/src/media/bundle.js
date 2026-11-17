const fs = require('fs');
const path = require('path');

const mediaDir = __dirname;
const uiCorePath = path.join(mediaDir, 'airmuse_ui_core.js');
const appleProviderPath = path.join(mediaDir, 'provider', 'apple_music_provider.js');
const outputPath = path.join(mediaDir, 'airmuse_apple_engine.js');

const uiCoreCode = fs.readFileSync(uiCorePath, 'utf8');
const appleProviderCode = fs.readFileSync(appleProviderPath, 'utf8');

const bundled = `// airmuse_apple_engine.js
// Auto-generated bundle: AirMuse UI Core + AppleMusicProvider
// DO NOT EDIT DIRECTLY: Modify src/media/airmuse_ui_core.js or src/media/provider/apple_music_provider.js instead.

(function () {
    if (window.__airmuseEngineInited) return;

    function bootstrap() {
        if (!document.body) {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
            } else {
                setTimeout(bootstrap, 50);
            }
            return;
        }

        if (window.__airmuseEngineInited) return;
        window.__airmuseEngineInited = true;

        // ── 1. 通用 UI 核心组件框架 (Universal UI Core) ──
        ${uiCoreCode}

        // ── 2. Apple Music 音源适配器 (AppleMusicProvider) ──
        ${appleProviderCode}

        // ── 3. 实例化并启动应用 ──
        const provider = new window.AppleMusicProvider();
        window.AirMuseUI.init(provider);
    }

    bootstrap();
})();
`;

fs.writeFileSync(outputPath, bundled, 'utf8');
console.log(`[Bundle] Successfully bundled airmuse_apple_engine.js (${bundled.length} bytes)`);

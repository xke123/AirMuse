#pragma once

#include <windows.h>
#include <string>
#include <vector>
#include <functional>

namespace AirPlay {

// TAK Audio Decoder Library function pointer signatures (from tak_deco_lib.dll / TAKDECLIB)
typedef void* TtakSSD;

typedef int  (__cdecl *pfn_tak_GetLibraryVersion)(int* version);
typedef const char* (__cdecl *pfn_tak_GetCodecName)();
typedef TtakSSD (__cdecl *pfn_tak_SSD_Create_FromFile)(const char* fileName, void* options);
typedef void (__cdecl *pfn_tak_SSD_Destroy)(TtakSSD ssd);
typedef int  (__cdecl *pfn_tak_SSD_GetStreamInfo)(TtakSSD ssd, void* streamInfo);
typedef int  (__cdecl *pfn_tak_SSD_ReadAudio)(TtakSSD ssd, void* sampleBuffer, int sampleNum);
typedef int  (__cdecl *pfn_tak_SSD_Seek)(TtakSSD ssd, int64_t samplePos);
typedef int  (__cdecl *pfn_tak_SSD_GetReadPos)(TtakSSD ssd, int64_t* samplePos);

class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();

    bool Initialize(const std::wstring& dllPath);
    void Shutdown();

    // Playback control
    bool OpenFile(const std::wstring& filePath);
    void Play();
    void Pause();
    void Stop();
    void Seek(double seconds);
    void SetVolume(float volume); // 0.0 to 1.0

    // State getters
    bool IsPlaying() const { return m_isPlaying; }
    double GetDuration() const { return m_duration; }
    double GetPosition() const { return m_currentPos; }

    // Waveform / Spectrum callback
    using SpectrumCallback = std::function<void(const float* fftData, int size)>;
    void SetSpectrumCallback(SpectrumCallback cb) { m_spectrumCb = cb; }

private:
    HMODULE m_takDll = nullptr;
    pfn_tak_GetLibraryVersion m_takGetVersion = nullptr;
    pfn_tak_SSD_Create_FromFile m_takCreateFromFile = nullptr;
    pfn_tak_SSD_Destroy m_takDestroy = nullptr;
    pfn_tak_SSD_ReadAudio m_takReadAudio = nullptr;
    pfn_tak_SSD_Seek m_takSeek = nullptr;

    TtakSSD m_currentTakStream = nullptr;

    bool m_isPlaying = false;
    double m_duration = 0.0;
    double m_currentPos = 0.0;
    float m_volume = 1.0f;

    SpectrumCallback m_spectrumCb;
};

} // namespace AirPlay

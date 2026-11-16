#pragma once
#include "../core/Models.hpp"

namespace airmuse {

class IMediaSourceProvider {
public:
    virtual ~IMediaSourceProvider() = default;

    virtual std::wstring Id() const = 0;
    virtual int BasePriority() const = 0;
    virtual bool IsAvailable() const = 0;
    virtual NowPlayingState GetState() const = 0;

    virtual void PlayPause() = 0;
    virtual void Stop() = 0;
    virtual void Next() = 0;
    virtual void Previous() = 0;
    virtual void SeekTo(int64_t positionMs) = 0;
    virtual void SetVolume(float volume0to1) = 0;
};

} // namespace airmuse
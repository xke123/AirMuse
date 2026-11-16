#pragma once
#include <mutex>
#include "core/domain/MediaSnapshot.hpp"
namespace airmuse { class PlaybackClock { public: void Calibrate(const MediaSnapshot&); Milliseconds PositionAt(std::chrono::steady_clock::time_point now=std::chrono::steady_clock::now())const; private: mutable std::mutex mutex_; Milliseconds base_{}; Milliseconds duration_{}; double rate_{1.0}; PlaybackStatus state_{PlaybackStatus::Unknown}; std::chrono::steady_clock::time_point sampled_{std::chrono::steady_clock::now()}; }; }

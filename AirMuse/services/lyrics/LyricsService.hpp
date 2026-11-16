#pragma once
#include <functional>
#include <thread>
#include <mutex>
#include <optional>
#include <unordered_map>
#include "services/lyrics/LyricsTypes.hpp"
namespace airmuse { class LyricsService { public: using Loader=std::function<Lyrics(const MediaSnapshot&,std::stop_token)>; explicit LyricsService(Loader); ~LyricsService(); void Request(const MediaSnapshot&,std::function<void(const Lyrics&)>); private: Loader loader_;std::mutex mutex_;std::jthread task_;std::uint64_t generation_{};std::unordered_map<std::string,Lyrics> cache_; }; }

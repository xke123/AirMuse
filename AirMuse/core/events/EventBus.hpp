#pragma once
#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>
#include "core/domain/MediaSnapshot.hpp"

namespace airmuse {
struct MediaEvent { enum class Kind { SessionDiscovered, SessionRemoved, SnapshotChanged, ProviderDisconnected, ProviderError }; Kind kind; ProviderId providerId; SessionId sessionId; MediaSnapshot snapshot; std::string message; };
class Subscription { public: Subscription() = default; explicit Subscription(std::function<void()> cancel): cancel_(std::move(cancel)) {} Subscription(Subscription&& o) noexcept : cancel_(std::move(o.cancel_)) {} Subscription& operator=(Subscription&& o) noexcept { Reset(); cancel_=std::move(o.cancel_); return *this; } ~Subscription(){Reset();} Subscription(const Subscription&)=delete; void Reset(){if(cancel_){cancel_();cancel_={};}} private: std::function<void()> cancel_; };
class EventBus {
public:
    using Callback = std::function<void(const MediaEvent&)>;
    Subscription Subscribe(Callback callback) { auto alive=std::make_shared<std::atomic_bool>(true); std::lock_guard lock(mutex_); listeners_.push_back({alive,std::move(callback)}); return Subscription([alive]{alive->store(false);}); }
    void Publish(const MediaEvent& event) { std::vector<Listener> copy; { std::lock_guard lock(mutex_); listeners_.erase(std::remove_if(listeners_.begin(),listeners_.end(),[](const auto& x){return !x.alive->load();}),listeners_.end()); copy=listeners_; } for(auto& l:copy) if(l.alive->load()) l.callback(event); }
private: struct Listener { std::shared_ptr<std::atomic_bool> alive; Callback callback; }; std::mutex mutex_; std::vector<Listener> listeners_;
};
} // namespace airmuse

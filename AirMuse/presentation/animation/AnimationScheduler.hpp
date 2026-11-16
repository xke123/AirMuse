#pragma once
#include <functional>
#include <unordered_map>
namespace airmuse { class AnimationScheduler { public: using Id=unsigned long long; Id Start(float from,float to,float seconds,std::function<void(float)>); void Cancel(Id); void Tick(float seconds); private: struct Tween{float value,target,duration,elapsed{};std::function<void(float)> update;};Id next_{};std::unordered_map<Id,Tween> tweens_;}; }

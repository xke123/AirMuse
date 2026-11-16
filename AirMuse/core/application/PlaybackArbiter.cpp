#include "core/application/PlaybackArbiter.hpp"
#include <algorithm>
namespace airmuse { namespace { std::string Key(const ProviderId&p,const SessionId&s){return p+"\x1f"+s;} }
void PlaybackArbiter::Observe(const MediaSnapshot&s){ auto k=Key(s.providerId,s.sessionId); auto it=sessions_.find(k); if(it==sessions_.end()||IsNewer(s,it->second)) sessions_[k]=s; }
void PlaybackArbiter::Remove(const ProviderId&p,const SessionId&s){sessions_.erase(Key(p,s));}
void PlaybackArbiter::SetPreferredProvider(std::optional<ProviderId> p){preferred_=std::move(p);} void PlaybackArbiter::Lock(std::optional<SessionId>s){locked_=std::move(s);}
std::optional<MediaSnapshot> PlaybackArbiter::Active() const { const MediaSnapshot* best=nullptr; auto score=[&](const MediaSnapshot&s){int n=s.status==PlaybackStatus::Playing?100:0; if(preferred_&&s.providerId==*preferred_)n+=30; if(locked_&&s.sessionId==*locked_)n+=1000; return n;}; for(const auto&[_,s]:sessions_) if(!best||score(s)>score(*best)||(score(s)==score(*best)&&s.updatedAt>best->updatedAt)) best=&s; return best?std::optional<MediaSnapshot>(*best):std::nullopt; }
} // namespace airmuse

#include <cassert>
#include <iostream>
#include "core/application/PlaybackArbiter.hpp"
#include "core/application/PlaybackCoordinator.hpp"
#include "providers/mock/MockProvider.hpp"
#include "services/lyrics/LyricsParser.hpp"
using namespace airmuse;
int main(){auto lyrics=LyricsParser::ParseLrc("[00:01.20]one\n[00:02.00][00:03.00]two");assert(lyrics.lines.size()==3&&lyrics.lines[0].at==Milliseconds(1200));PlaybackArbiter a;MediaSnapshot paused;paused.providerId="a";paused.sessionId="one";paused.status=PlaybackStatus::Paused;paused.revision=1;MediaSnapshot playing=paused;playing.providerId="b";playing.sessionId="two";playing.status=PlaybackStatus::Playing;a.Observe(paused);a.Observe(playing);assert(a.Active()->sessionId=="two");EventBus bus;ProviderManager manager(bus);PlaybackCoordinator c(bus,manager);auto mock=std::make_shared<MockProvider>();assert(manager.Register(mock));MediaSnapshot s;s.sessionId="x";s.status=PlaybackStatus::Paused;s.capabilities=mock->GetCapabilities();mock->AddSession(s);assert(c.Dispatch(PlaybackCommand::Play));assert(c.Active()->status==PlaybackStatus::Playing);std::cout<<"All architecture tests passed\n";}

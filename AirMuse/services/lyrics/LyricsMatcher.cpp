#include "services/lyrics/LyricsMatcher.hpp"
#include <algorithm>
#include <cctype>
#include <cstdlib>
namespace airmuse { namespace {std::string N(std::string s){std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});return s;}} int LyricsMatcher::Score(const MediaSnapshot&a,const MediaSnapshot&b){int x=0;if(N(a.title)==N(b.title))x+=55;if(N(a.artist)==N(b.artist))x+=30;if(!a.album.empty()&&N(a.album)==N(b.album))x+=10;auto d=std::llabs((a.duration-b.duration).count());if(d<2000)x+=5;else if(d>10000)x-=20;return x;} }

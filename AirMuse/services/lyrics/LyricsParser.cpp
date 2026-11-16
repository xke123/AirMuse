#include "services/lyrics/LyricsParser.hpp"
#include <algorithm>
#include <cstdio>
#include <sstream>
namespace airmuse { Lyrics LyricsParser::ParseLrc(std::string_view body){Lyrics r;std::istringstream in{std::string(body)};std::string line;while(std::getline(in,line)){size_t p=0;std::vector<Milliseconds> times;while(p<line.size()&&line[p]=='['){auto end=line.find(']',p);if(end==std::string::npos)break;auto tag=line.substr(p+1,end-p-1);int m=0,sec=0,ms=0;if(::sscanf_s(tag.c_str(),"%d:%d.%d",&m,&sec,&ms)>=2){if(ms<10)ms*=100;else if(ms<100)ms*=10;times.emplace_back((m*60+sec)*1000+ms);}p=end+1;}auto text=line.substr(p);for(auto t:times)r.lines.push_back({t,text,{}});}std::sort(r.lines.begin(),r.lines.end(),[](auto&a,auto&b){return a.at<b.at;});return r;} }

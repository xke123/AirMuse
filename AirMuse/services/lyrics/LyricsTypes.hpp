#pragma once
#include <string>
#include <vector>
#include "core/domain/MediaSnapshot.hpp"
namespace airmuse { struct LyricLine{Milliseconds at{};std::string text;std::string translation;}; struct Lyrics{MediaIdentity identity;std::vector<LyricLine> lines;}; }

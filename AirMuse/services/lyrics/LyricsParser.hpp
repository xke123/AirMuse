#pragma once
#include <string_view>
#include "services/lyrics/LyricsTypes.hpp"
namespace airmuse { class LyricsParser { public: static Lyrics ParseLrc(std::string_view); }; }

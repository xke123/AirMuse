#pragma once

#include <cstdint>
#include <vector>
#include <cstring>
#include <stdexcept>

namespace AirPlay {

/**
 * Reconstructed 32-bit ARGB RLE codec used by Zion's AirPlay media player.
 * Magic header: 'RLE\xf1' (0xF1454C52 in LE dword)
 * Followed by uint32_t width, uint32_t height, uint32_t flags (always 1).
 */
class RleCodec {
public:
    struct Bitmap32 {
        uint32_t width = 0;
        uint32_t height = 0;
        std::vector<uint32_t> pixels; // 32-bit ARGB (0xAARRGGBB)

        inline uint32_t GetPixel(uint32_t x, uint32_t y) const {
            if (x < width && y < height) return pixels[y * width + x];
            return 0;
        }

        inline void SetPixel(uint32_t x, uint32_t y, uint32_t color) {
            if (x < width && y < height) pixels[y * width + x] = color;
        }
    };

    static Bitmap32 Decode(const uint8_t* data, size_t size) {
        if (!data || size < 16) {
            throw std::runtime_error("RLE data too small or null");
        }
        if (std::memcmp(data, "RLE\xf1", 4) != 0) {
            throw std::runtime_error("Invalid RLE magic signature");
        }

        uint32_t width = *reinterpret_cast<const uint32_t*>(data + 4);
        uint32_t height = *reinterpret_cast<const uint32_t*>(data + 8);
        // uint32_t flags = *reinterpret_cast<const uint32_t*>(data + 12);

        Bitmap32 bmp;
        bmp.width = width;
        bmp.height = height;
        bmp.pixels.resize(width * height, 0);

        size_t pos = 16;
        size_t write_idx = 0;
        const size_t total_pixels = width * height;

        while (pos < size && write_idx < total_pixels) {
            uint8_t cmd = data[pos++];
            if (cmd == 0xFF) { // End of RLE stream marker
                break;
            }

            uint8_t tag = cmd >> 6;
            uint32_t count = (cmd & 0x3F) + 1;

            switch (tag) {
            case 0: {
                // Tag 0: Transparent run
                for (uint32_t i = 0; i < count && write_idx < total_pixels; ++i) {
                    bmp.pixels[write_idx++] = 0x00000000;
                }
                break;
            }
            case 1: {
                // Tag 1: Literal 32-bit ARGB pixels
                for (uint32_t i = 0; i < count && write_idx < total_pixels; ++i) {
                    if (pos + 4 > size) break;
                    uint8_t b = data[pos++];
                    uint8_t g = data[pos++];
                    uint8_t r = data[pos++];
                    uint8_t a = data[pos++];
                    bmp.pixels[write_idx++] = (static_cast<uint32_t>(a) << 24) |
                                              (static_cast<uint32_t>(r) << 16) |
                                              (static_cast<uint32_t>(g) << 8)  |
                                              static_cast<uint32_t>(b);
                }
                break;
            }
            case 2: {
                // Tag 2: Opaque 24-bit RGB pixels (alpha forced to 0xFF)
                for (uint32_t i = 0; i < count && write_idx < total_pixels; ++i) {
                    if (pos + 3 > size) break;
                    uint8_t b = data[pos++];
                    uint8_t g = data[pos++];
                    uint8_t r = data[pos++];
                    bmp.pixels[write_idx++] = 0xFF000000 |
                                              (static_cast<uint32_t>(r) << 16) |
                                              (static_cast<uint32_t>(g) << 8)  |
                                              static_cast<uint32_t>(b);
                }
                break;
            }
            case 3: {
                // Tag 3: Run-length repeated 32-bit ARGB pixel
                if (pos + 4 > size) break;
                uint8_t b = data[pos++];
                uint8_t g = data[pos++];
                uint8_t r = data[pos++];
                uint8_t a = data[pos++];
                uint32_t color = (static_cast<uint32_t>(a) << 24) |
                                 (static_cast<uint32_t>(r) << 16) |
                                 (static_cast<uint32_t>(g) << 8)  |
                                 static_cast<uint32_t>(b);
                for (uint32_t i = 0; i < count && write_idx < total_pixels; ++i) {
                    bmp.pixels[write_idx++] = color;
                }
                break;
            }
            }
        }

        return bmp;
    }

    static std::vector<uint8_t> Encode(const Bitmap32& bmp) {
        std::vector<uint8_t> out;
        out.reserve(bmp.width * bmp.height);

        // Header: 'RLE\xf1'
        out.push_back('R');
        out.push_back('L');
        out.push_back('E');
        out.push_back(0xF1);

        // Width, Height, Flags (1)
        uint32_t w = bmp.width;
        uint32_t h = bmp.height;
        uint32_t f = 1;
        const uint8_t* pw = reinterpret_cast<const uint8_t*>(&w);
        const uint8_t* ph = reinterpret_cast<const uint8_t*>(&h);
        const uint8_t* pf = reinterpret_cast<const uint8_t*>(&f);
        out.insert(out.end(), pw, pw + 4);
        out.insert(out.end(), ph, ph + 4);
        out.insert(out.end(), pf, pf + 4);

        size_t i = 0;
        const size_t total = bmp.pixels.size();

        while (i < total) {
            uint32_t p = bmp.pixels[i];
            uint8_t a = static_cast<uint8_t>((p >> 24) & 0xFF);
            uint8_t r = static_cast<uint8_t>((p >> 16) & 0xFF);
            uint8_t g = static_cast<uint8_t>((p >> 8) & 0xFF);
            uint8_t b = static_cast<uint8_t>(p & 0xFF);

            // Determine run length
            size_t run_len = 1;
            while (i + run_len < total && bmp.pixels[i + run_len] == p && run_len < 64) {
                run_len++;
            }

            if (a == 0) {
                // Tag 0: transparent run
                out.push_back(static_cast<uint8_t>(run_len - 1));
                i += run_len;
            } else if (run_len >= 2) {
                // Tag 3: repeated pixel
                out.push_back(static_cast<uint8_t>(0xC0 | (run_len - 1)));
                out.push_back(b);
                out.push_back(g);
                out.push_back(r);
                out.push_back(a);
                i += run_len;
            } else {
                // Check if sequential pixels are opaque
                size_t chunk_len = 1;
                bool all_opaque = (a == 255);
                while (i + chunk_len < total && chunk_len < 64) {
                    uint32_t next_p = bmp.pixels[i + chunk_len];
                    if (i + chunk_len + 2 < total &&
                        next_p == bmp.pixels[i + chunk_len + 1] &&
                        next_p == bmp.pixels[i + chunk_len + 2]) {
                        break;
                    }
                    if (((next_p >> 24) & 0xFF) != 255) {
                        all_opaque = false;
                    }
                    chunk_len++;
                }

                if (all_opaque) {
                    // Tag 2: opaque BGR
                    out.push_back(static_cast<uint8_t>(0x80 | (chunk_len - 1)));
                    for (size_t j = 0; j < chunk_len; ++j) {
                        uint32_t pj = bmp.pixels[i + j];
                        out.push_back(static_cast<uint8_t>(pj & 0xFF));
                        out.push_back(static_cast<uint8_t>((pj >> 8) & 0xFF));
                        out.push_back(static_cast<uint8_t>((pj >> 16) & 0xFF));
                    }
                } else {
                    // Tag 1: ARGB
                    out.push_back(static_cast<uint8_t>(0x40 | (chunk_len - 1)));
                    for (size_t j = 0; j < chunk_len; ++j) {
                        uint32_t pj = bmp.pixels[i + j];
                        out.push_back(static_cast<uint8_t>(pj & 0xFF));
                        out.push_back(static_cast<uint8_t>((pj >> 8) & 0xFF));
                        out.push_back(static_cast<uint8_t>((pj >> 16) & 0xFF));
                        out.push_back(static_cast<uint8_t>((pj >> 24) & 0xFF));
                    }
                }
                i += chunk_len;
            }
        }

        out.push_back(0xFF); // End marker
        return out;
    }
};

} // namespace AirPlay

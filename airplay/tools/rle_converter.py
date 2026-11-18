"""
AirPlay RLE Image Converter
Encodes and decodes 32-bit ARGB bitmaps using the AirPlay RLE\\xf1 format.
"""

import sys
import struct
from PIL import Image

def decode_rle(data: bytes) -> Image.Image:
    if not data.startswith(b'RLE\xf1'):
        raise ValueError("Invalid RLE magic (expected 'RLE\\xf1')")
    w, h, flags = struct.unpack('<III', data[4:16])
    pixels = []
    pos = 16
    total_pixels = w * h
    while pos < len(data):
        cmd = data[pos]
        pos += 1
        if cmd == 0xFF:
            break
        tag = cmd >> 6
        count = (cmd & 0x3F) + 1
        if tag == 0:
            pixels.extend([(0, 0, 0, 0)] * count)
        elif tag == 1:
            for _ in range(count):
                b, g, r, a = data[pos:pos+4]
                pos += 4
                pixels.append((r, g, b, a))
        elif tag == 2:
            for _ in range(count):
                b, g, r = data[pos:pos+3]
                pos += 3
                pixels.append((r, g, b, 255))
        elif tag == 3:
            b, g, r, a = data[pos:pos+4]
            pos += 4
            pixels.extend([(r, g, b, a)] * count)
    img = Image.new('RGBA', (w, h))
    img.putdata(pixels[:total_pixels])
    return img

def encode_rle(img: Image.Image) -> bytes:
    img = img.convert('RGBA')
    w, h = img.size
    pixels = list(img.getdata())
    
    out = bytearray()
    out.extend(b'RLE\xf1')
    out.extend(struct.pack('<III', w, h, 1))
    
    i = 0
    total = len(pixels)
    while i < total:
        p = pixels[i]
        r, g, b, a = p
        
        # Check run of identical pixels
        run_len = 1
        while i + run_len < total and pixels[i + run_len] == p and run_len < 64:
            run_len += 1
            
        if a == 0:
            # Tag 0: transparent run
            out.append(0x00 | (run_len - 1))
            i += run_len
        elif run_len >= 2:
            # Tag 3: repeated ARGB pixel
            out.append(0xC0 | (run_len - 1))
            out.extend([b, g, r, a])
            i += run_len
        else:
            # Tag 1 (ARGB) or Tag 2 (opaque RGB)
            # Count sequential non-run pixels up to 64
            chunk_len = 1
            all_opaque = (a == 255)
            while i + chunk_len < total and chunk_len < 64:
                next_p = pixels[i + chunk_len]
                # If next starts a long run >= 3, stop chunk here
                if i + chunk_len + 2 < total and next_p == pixels[i + chunk_len + 1] == pixels[i + chunk_len + 2]:
                    break
                if next_p[3] != 255:
                    all_opaque = False
                chunk_len += 1
                
            if all_opaque:
                # Tag 2: opaque BGR run
                out.append(0x80 | (chunk_len - 1))
                for j in range(chunk_len):
                    pj = pixels[i + j]
                    out.extend([pj[2], pj[1], pj[0]])
            else:
                # Tag 1: raw ARGB run
                out.append(0x40 | (chunk_len - 1))
                for j in range(chunk_len):
                    pj = pixels[i + j]
                    out.extend([pj[2], pj[1], pj[0], pj[3]])
            i += chunk_len
            
    out.append(0xFF) # End-of-stream delimiter
    return bytes(out)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python rle_converter.py <decode|encode> <input_file> <output_file>")
        sys.exit(1)
        
    action, in_file, out_file = sys.argv[1], sys.argv[2], sys.argv[3]
    if action == "decode":
        with open(in_file, "rb") as f:
            data = f.read()
        im = decode_rle(data)
        im.save(out_file)
        print(f"[OK] Decoded {in_file} -> {out_file} ({im.width}x{im.height})")
    elif action == "encode":
        im = Image.open(in_file)
        rle_data = encode_rle(im)
        with open(out_file, "wb") as f:
            f.write(rle_data)
        print(f"[OK] Encoded {in_file} ({im.width}x{im.height}) -> {out_file} ({len(rle_data)} bytes)")

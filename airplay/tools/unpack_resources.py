"""
AirPlay Resource Unpacker & Converter
Extracts all PE resources from AIRPLAY-zion_unpacked.exe and decodes RLE bitmaps.
"""

import os
import sys
import struct
import json
import pefile
from PIL import Image

def decode_airplay_rle(data: bytes):
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
            # Transparent run (count pixels of 0x00000000)
            pixels.extend([(0, 0, 0, 0)] * count)
        elif tag == 1:
            # Raw 32-bit ARGB run (count unique ARGB pixels)
            for _ in range(count):
                b, g, r, a = data[pos:pos+4]
                pos += 4
                pixels.append((r, g, b, a))
        elif tag == 2:
            # Opaque 24-bit RGB run (alpha=255)
            for _ in range(count):
                b, g, r = data[pos:pos+3]
                pos += 3
                pixels.append((r, g, b, 255))
        elif tag == 3:
            # RLE repeated 32-bit ARGB pixel (count copies of 1 pixel)
            b, g, r, a = data[pos:pos+4]
            pos += 4
            pixels.extend([(r, g, b, a)] * count)
    img = Image.new('RGBA', (w, h))
    img.putdata(pixels[:total_pixels])
    return w, h, flags, img

def unpack_executable(exe_path: str, output_dir: str):
    print(f"[*] Opening {exe_path}...")
    pe = pefile.PE(exe_path)
    
    bitmaps_dir = os.path.join(output_dir, "resources", "bitmaps")
    icons_dir = os.path.join(output_dir, "resources", "icons")
    binaries_dir = os.path.join(output_dir, "resources", "binaries")
    raw_dir = os.path.join(output_dir, "resources", "raw_rcdata")
    
    for d in [bitmaps_dir, icons_dir, binaries_dir, raw_dir]:
        os.makedirs(d, exist_ok=True)
        
    manifest = []
    
    for rsrc in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if rsrc.struct.Id == 10:  # RT_RCDATA
            for entry in rsrc.directory.entries:
                name = str(entry.name)
                data_entry = entry.directory.entries[0].data
                raw = pe.get_data(data_entry.struct.OffsetToData, data_entry.struct.Size)
                
                # Raw dump
                raw_path = os.path.join(raw_dir, f"{name}.bin")
                with open(raw_path, "wb") as f:
                    f.write(raw)
                    
                meta = {
                    "name": name,
                    "type": "RT_RCDATA",
                    "raw_size": len(raw),
                    "raw_file": f"resources/raw_rcdata/{name}.bin"
                }
                
                if raw.startswith(b'RLE\xf1'):
                    w, h, flags, img = decode_airplay_rle(raw)
                    png_path = os.path.join(bitmaps_dir, f"{name}.png")
                    img.save(png_path)
                    meta.update({
                        "kind": "RLE_BITMAP",
                        "width": w,
                        "height": h,
                        "flags": flags,
                        "png_file": f"resources/bitmaps/{name}.png"
                    })
                    print(f"[RLE] {name:16s} ({w:3d}x{h:2d}) -> {png_path}")
                elif name == "TAKDECLIB":
                    dll_path = os.path.join(binaries_dir, "tak_deco_lib.dll")
                    with open(dll_path, "wb") as f:
                        f.write(raw)
                    meta.update({
                        "kind": "NATIVE_DLL",
                        "binary_file": "resources/binaries/tak_deco_lib.dll",
                        "desc": "TAK Audio Lossless Decoder DLL"
                    })
                    print(f"[DLL] {name:16s} ({len(raw):6d} bytes) -> {dll_path}")
                elif name == "PYCODE":
                    dat_path = os.path.join(binaries_dir, "pinyin_index_table.dat")
                    with open(dat_path, "wb") as f:
                        f.write(raw)
                    meta.update({
                        "kind": "DATA_TABLE",
                        "binary_file": "resources/binaries/pinyin_index_table.dat",
                        "desc": "GBK Pinyin Initial Index Table (256 KB)"
                    })
                    print(f"[DAT] {name:16s} ({len(raw):6d} bytes) -> {dat_path}")
                elif name in ("AUDIO", "PLAYLIST"):
                    ico_path = os.path.join(icons_dir, f"icon_{name.lower()}_file.ico")
                    with open(ico_path, "wb") as f:
                        f.write(raw)
                    meta.update({
                        "kind": "ICON",
                        "icon_file": f"resources/icons/icon_{name.lower()}_file.ico",
                        "desc": f"File Association Icon for {name}"
                    })
                    print(f"[ICO] {name:16s} ({len(raw):6d} bytes) -> {ico_path}")
                manifest.append(meta)
                
    manifest_path = os.path.join(output_dir, "resources", "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f"[OK] Successfully unpacked all resources to {output_dir}")

if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "AIRPLAY-zion_unpacked.exe"
    dst = sys.argv[2] if len(sys.argv) > 2 else "."
    unpack_executable(src, dst)

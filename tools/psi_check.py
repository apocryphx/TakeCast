#!/usr/bin/env python3
"""Extract and validate PSI sections (PAT/PMT/SDT) from a TS file."""
import sys

def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1) & 0xFFFFFFFF
    return crc

def analyze(path, max_sections=6):
    data = open(path, "rb").read()
    seen = set()
    for i in range(len(data) // 188):
        p = data[i * 188:(i + 1) * 188]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid not in (0x0000, 0x1000, 0x0011):
            continue
        if not (p[1] & 0x40):
            continue
        if pid in seen and len(seen) >= 3:
            continue
        seen.add(pid)
        pointer = p[4]
        s = p[5 + pointer:]
        table_id = s[0]
        section_len = ((s[1] & 0x0F) << 8) | s[2]
        section = s[:3 + section_len]
        crc_ok = crc32_mpeg(section) == 0
        name = {0: "PAT", 0x1000: "PMT", 0x11: "SDT"}[pid]
        print(f"  {name} table_id={table_id:#04x} section_len={section_len} "
              f"total={3 + section_len} CRC {'OK' if crc_ok else 'BAD'}")
        print(f"    bytes: {section.hex()}")
        if len(seen) >= max_sections:
            break

for path in sys.argv[1:]:
    print(f"=== {path}")
    analyze(path)

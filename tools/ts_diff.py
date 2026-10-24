#!/usr/bin/env python3
"""Structural diff of two MPEG-TS files: PID census, PSI cadence, PES flags."""
import sys
from collections import Counter, defaultdict

def analyze(path):
    data = open(path, "rb").read()
    n = len(data) // 188
    pids = Counter()
    psi_positions = defaultdict(list)
    pes_flags = {}
    pcr_count = 0
    first_pcr = None
    last_pcr = None
    for i in range(n):
        p = data[i * 188:(i + 1) * 188]
        if p[0] != 0x47:
            print(f"  SYNC LOSS at packet {i}")
            break
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pusi = bool(p[1] & 0x40)
        afc = (p[3] >> 4) & 0x3
        pids[pid] += 1
        if pid in (0x0000, 0x1000) and pusi:
            psi_positions[pid].append(i)
        # adaptation field with PCR
        if afc & 0x2 and p[4] > 0 and (p[5] & 0x10):
            pcr_count += 1
            base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
            if first_pcr is None:
                first_pcr = base
            last_pcr = base
        # PES header flags on payload start of media pids
        if pusi and pid not in (0x0000, 0x1000, 0x11) and pid not in pes_flags:
            off = 4
            if afc & 0x2:
                off += 1 + p[4]
            if p[off:off + 3] == b"\x00\x00\x01":
                stream_id = p[off + 3]
                flags2 = p[off + 7]
                hdrlen = p[off + 8]
                pes_flags[pid] = (hex(stream_id), f"pts_dts_flags={flags2 >> 6:#04b}", f"hdrlen={hdrlen}")
    dur = (last_pcr - first_pcr) / 90000.0 if first_pcr is not None and last_pcr is not None else 0
    print(f"  packets={n}")
    for pid in sorted(pids):
        print(f"  PID {pid:#06x}: {pids[pid]} packets")
    for pid, positions in sorted(psi_positions.items()):
        name = "PAT" if pid == 0 else "PMT"
        gaps = [b - a for a, b in zip(positions, positions[1:])]
        print(f"  {name} count={len(positions)} first_at={positions[0]}"
              f" repeat_gap_packets={gaps[:3] if gaps else 'none'}")
    print(f"  PCR count={pcr_count} span={dur:.2f}s"
          f" (~{pcr_count / dur if dur else 0:.1f}/s)")
    for pid, info in sorted(pes_flags.items()):
        print(f"  PES on PID {pid:#06x}: stream_id={info[0]} {info[1]} {info[2]}")

for path in sys.argv[1:]:
    print(f"=== {path.split('/')[-1]}")
    analyze(path)

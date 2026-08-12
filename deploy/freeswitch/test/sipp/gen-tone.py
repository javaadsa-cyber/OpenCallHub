#!/usr/bin/env python3
# 生成 2 秒 440Hz μ-law 裸采样文件（8kHz、1 字节/采样，约 16KB），供 sipp rtp_stream 放流。
# rtp_stream 要求无 wav 头的裸采样；PCMU payload type 0，20ms/帧 = 160 字节。
# 用法：python3 gen-tone.py <输出路径>
import audioop
import math
import os
import struct
import sys

out = sys.argv[1] if len(sys.argv) > 1 else 'tone_pcmu.raw'
RATE, FREQ, SECS, AMP = 8000, 440, 2, 0.9

pcm = b''.join(
    struct.pack('<h', int(AMP * 32767 * math.sin(2 * math.pi * FREQ * i / RATE)))
    for i in range(RATE * SECS)
)
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
with open(out, 'wb') as f:
    f.write(audioop.lin2ulaw(pcm, 2))
print(f'{out}: {os.path.getsize(out)} bytes ({SECS}s {FREQ}Hz ulaw)')

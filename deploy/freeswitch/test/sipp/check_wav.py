#!/usr/bin/env python3
# 校验 FS uuid_record 录音文件，证明 sipp→FS 方向有真实 RTP：
#   ① 文件大小达标（3 秒 G.711 录音理论约 24-48KB，阈值 20KB）
#   ② PCM 采样方差大于阈值——纯静音帧方差≈0，440Hz 音调方差很大。
#      仅靠大小断言不可靠：即使 sipp 不发 RTP，FS soft timer 也会写静音帧产生非零文件。
# 对 wav 编码格式不敏感（PCMU-in-wav 或 16bit linear 均可）：直接对 data 块原始字节求方差。
# 用法：python3 check_wav.py <wav路径>；通过打印 OK 并退出 0，失败抛 AssertionError。
import struct
import sys

path = sys.argv[1]
data = open(path, 'rb').read()
size = len(data)
assert size >= 20 * 1024, f'录音文件过小：{size} 字节（期望 >= 20KB）'

# 解析 wav 的 data 块；找不到时兜底跳过 44 字节标准头
i = data.find(b'data')
if i >= 0 and i + 8 <= size:
    (length,) = struct.unpack('<I', data[i + 4:i + 8])
    body = data[i + 8:i + 8 + length]
else:
    body = data[44:]
assert len(body) >= 4096, f'data 块过小：{len(body)} 字节'

mean = sum(body) / len(body)
var = sum((b - mean) ** 2 for b in body) / len(body)
print(f'size={size}B samples={len(body)} mean={mean:.1f} variance={var:.1f}')
assert var > 200, f'采样方差过低（{var:.1f}）：录音是静音，RTP 未到达 FS'
print('OK')

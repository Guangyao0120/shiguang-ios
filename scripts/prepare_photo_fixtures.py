import struct,zlib,os
from pathlib import Path
root=Path(os.environ['RUNNER_TEMP'])/'PhotoFixtures';root.mkdir(exist_ok=True)
for i in range(3):
    w,h=1200,900
    raw=b''.join(b'\0'+bytes([35+i*50,100+y//6,180-i*40])*w for y in range(h))
    def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    (root/f'photo-{i}.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))

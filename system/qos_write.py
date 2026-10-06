import mmap, os, struct, sys
base = int(sys.argv[1], 16); value = int(sys.argv[2], 16)
f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(f, 0x1000, offset=base & ~0xFFF)
off = base & 0xFFF
old = struct.unpack_from('<I', mm, off + 0x08)[0]
struct.pack_into('<I', mm, off + 0x08, value)
new = struct.unpack_from('<I', mm, off + 0x08)[0]
print(f'{base:#x} QOS_PRIORITY: {old:08x} -> {value:08x} (readback {new:08x})')

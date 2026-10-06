import mmap, os, struct, sys
name, base = sys.argv[1], int(sys.argv[2], 16)
f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(f, 0x1000, offset=base & ~0xFFF)
off = base & 0xFFF
vals = [struct.unpack_from('<I', mm, off + r)[0] for r in (0x00, 0x04, 0x08, 0x0c, 0x10, 0x14)]
print(f'{name} @{base:#x}: ' + ' '.join(f'{v:08x}' for v in vals))

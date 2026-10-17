#!/usr/bin/env python3
"""debug_serial.py <build-dir> — debug builds (DEBUG_LOG=1) only.

Turn Wine's ERR/WARN/FIXME messages back on in the wine9x build and send
them to the guest's COM1, so QEMU (-serial file:...) records them on the
host. TRACE stays compiled out (far too verbose under emulation).

  - Makefile: drop -DWINE_SILENT and -DWINE_NO_DEBUG_MSGS (keep NO_TRACE)
  - compact/debug.c: default_dbg_vprintf formats the message and writes it
    to COM1, opening the port per message so all four DLLs can share it;
    headers read "class:channel:function" (e.g. warn:ddraw:d3d_device_init)
"""
import os, re, sys

build = sys.argv[1]

mk = os.path.join(build, 'Makefile')
s = open(mk).read()
s2 = s.replace('-DWINE_SILENT ', '').replace(' -DWINE_NO_DEBUG_MSGS', '')
if s2 == s:
    sys.exit('debug_serial: Makefile flags not found')
open(mk, 'w').write(s2)

dc = os.path.join(build, 'compact', 'debug.c')
s = open(dc).read()
s = s.replace('#define LOG_FILE', '/* LOG_FILE off: messages go to COM1 */', 1)
# Header "class:channel:function": the formatter in use does not know the '#'
# flag, so "[%#x]" printed literally without consuming its argument and every
# later field shifted ("err:[%#x]:(null):ddraw", function name lost). The
# thread id is 0 on Win9x anyway (patched in the Dockerfile), so drop it.
s, n = re.subn(r'wine_dbg_printf\( "%s:\[%#x\]:%s:%s ", debug_classes\[cls\], (?:0|GetCurrentThreadId\(\)), channel->name, func \)',
               'wine_dbg_printf( "%s:%s:%s ", debug_classes[cls], channel->name, func )', s)
if n != 1:
    sys.exit('debug_serial: message header not found')
m = re.search(r'static int default_dbg_vprintf\( const char \*format, va_list args \)\n\{.*?\n\}\n', s, re.S)
if not m:
    sys.exit('debug_serial: default_dbg_vprintf not found')
s = s[:m.start()] + '''static int default_dbg_vprintf( const char *format, va_list args )
{
    /* debug build: every message to COM1 (QEMU -serial file:...) */
    char buf[1024];
    DWORD len, written;
    HANDLE port;
    int n = _vsnprintf( buf, sizeof(buf) - 1, format, args );

    if (n < 0) n = sizeof(buf) - 1;
    buf[n] = 0;
    len = (DWORD)n;
    port = CreateFileA( "COM1", GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL );
    if (port != INVALID_HANDLE_VALUE)
    {
        WriteFile( port, buf, len, &written, NULL );
        CloseHandle( port );
    }
    return n;
}
''' + s[m.end():]
open(dc, 'w').write(s)
print('debug build: ERR/WARN/FIXME -> COM1')

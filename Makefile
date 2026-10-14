# Makefile — build and run qemu3dfx unit tests on Linux
#
# Usage (from repo root):
#   make test       build and run all test suites
#   make test-emu   differential emulator tests vs the qemu-3dfx reference
#                   DLLs (tests/emu/README.md)
#   make clean      remove test binaries

CC     = gcc
CFLAGS = -D_WIN32 -Itests/include -Wall -Wextra \
         -Wno-unused-parameter -Wno-unused-function \
         -std=c11 -O0

TEST_BINS = tests/run_test_hooks \
            tests/run_test_hooks_1_8 \
            tests/run_test_ddraw_stubs

.PHONY: test test-emu clean

# ── Default target: build + run ───────────────────────────────────
test: $(TEST_BINS)
	@echo "--- Running test_hooks ---"
	@tests/run_test_hooks
	@tests/run_test_hooks_1_8
	@echo "--- Running test_ddraw_stubs ---"
	@tests/run_test_ddraw_stubs
	@echo "--- All test suites passed ---"

# ── Link rules ────────────────────────────────────────────────────

# test_hooks.c includes qemu3dfx_hooks.c (Windows API mocked by mock_win32.c);
# built once with Wine 8.0 and once with Wine 1.8 module behaviour
HOOKS_DEPS = tests/test_hooks.c tests/mock_win32.c tests/mock_win32.h \
             tests/include/windows.h qemu3dfx_hooks.c

tests/run_test_hooks: $(HOOKS_DEPS)
	$(CC) $(CFLAGS) -DQEMU3DFX_WINE_MAJOR=8 -DQEMU3DFX_WINE_MINOR=0 \
		-o $@ tests/test_hooks.c tests/mock_win32.c

tests/run_test_hooks_1_8: $(HOOKS_DEPS)
	$(CC) $(CFLAGS) -DQEMU3DFX_WINE_MAJOR=1 -DQEMU3DFX_WINE_MINOR=8 \
		-o $@ tests/test_hooks.c tests/mock_win32.c

# test_ddraw_stubs.c includes qemu3dfx_ddraw_hooks.c (Win32 mocked by mock_win32.c)
tests/run_test_ddraw_stubs: tests/test_ddraw_stubs.c tests/mock_win32.c \
                             tests/include/windows.h qemu3dfx_ddraw_hooks.c
	$(CC) $(CFLAGS) -o $@ tests/test_ddraw_stubs.c tests/mock_win32.c

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -f $(TEST_BINS)
	rm -rf tests/emu/build

# ── Emulator differential tests (Unicorn + mingw-w64; see tests/emu/README.md)
test-emu:
	@bash tests/emu/run.sh

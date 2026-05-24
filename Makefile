# Makefile — build and run qemu3dfx unit tests on Linux
#
# Usage (from repo root):
#   make test       build and run all test suites
#   make clean      remove test binaries

CC     = gcc
CFLAGS = -D_WIN32 -Itests/include -Wall -Wextra \
         -Wno-unused-parameter -Wno-unused-function \
         -std=c11 -O0

TEST_BINS = tests/run_test_hooks \
            tests/run_test_ddraw_stubs \
            tests/run_test_passthrough

.PHONY: test clean

# ── Default target: build + run ───────────────────────────────────
test: $(TEST_BINS)
	@echo "--- Running test_hooks ---"
	@tests/run_test_hooks
	@echo "--- Running test_ddraw_stubs ---"
	@tests/run_test_ddraw_stubs
	@echo "--- Running test_passthrough ---"
	@tests/run_test_passthrough
	@echo "--- All test suites passed ---"

# ── Link rules ────────────────────────────────────────────────────

# test_hooks.c includes qemu3dfx_hooks.c (Windows API mocked by mock_win32.c)
tests/run_test_hooks: tests/test_hooks.c tests/mock_win32.c \
                      tests/include/windows.h qemu3dfx_hooks.c
	$(CC) $(CFLAGS) -o $@ tests/test_hooks.c tests/mock_win32.c

# test_ddraw_stubs.c includes qemu3dfx_ddraw_hooks.c (no Windows API calls)
tests/run_test_ddraw_stubs: tests/test_ddraw_stubs.c \
                             tests/include/windows.h qemu3dfx_ddraw_hooks.c
	$(CC) $(CFLAGS) -o $@ tests/test_ddraw_stubs.c

# test_passthrough.c provides mock wined3d exports and includes passthrough.c
tests/run_test_passthrough: tests/test_passthrough.c \
                             tests/include/windows.h qemu3dfx_ddraw_passthrough.c
	$(CC) $(CFLAGS) -o $@ tests/test_passthrough.c

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -f $(TEST_BINS)

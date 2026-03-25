#!/bin/bash
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-global-cache}"
zig build -Doptimize=ReleaseFast
./zig-out/bin/LambLife

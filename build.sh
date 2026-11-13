#!/bin/sh
# Build all repro/diagnostic binaries into ./bin (requires Xcode Command Line Tools).
set -eu
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O repro/leak-repro.swift -o bin/leak-repro
for f in repro/workaround-proof.m tools/observer-capture.m tools/teardown-trace.m; do
  clang -fno-objc-arc "$f" -framework AppKit -o "bin/$(basename "$f" .m)"
done
ls bin

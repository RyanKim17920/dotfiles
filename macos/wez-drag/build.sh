#!/bin/sh
# Build wez-drag (Finder drag and drop helper for WezTerm) into ~/.local/bin.
# Needs only the Command Line Tools: one file, plain swiftc (no SwiftPM).
set -eu
cd "$(dirname "$0")"
out=${1:-$HOME/.local/bin/wez-drag}
mkdir -p "$(dirname "$out")"
swiftc -O -framework AppKit main.swift -o "$out.tmp"
mv -f "$out.tmp" "$out"
echo "built $out"

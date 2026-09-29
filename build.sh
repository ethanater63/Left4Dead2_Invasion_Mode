#!/usr/bin/env bash
#
# Compiles scripting/l4d2_invasion.sp into plugins/l4d2_invasion.smx.
#
# spcomp MUST come from the same SourceMod version as the server: 1.12.0-git7253.
# Resolution order:
#   1. $SPCOMP            - full path to a spcomp binary you already have
#   2. build/sourcemod/addons/sourcemod/scripting/spcomp[.exe]  - local toolchain
#   3. download SourceMod 1.12.0-git7253 into build/ and use its spcomp
#
# The build is treated as failed if spcomp emits any warning.

set -euo pipefail

SM_VERSION="1.12.0-git7253"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_ROOT/build"
TOOLCHAIN="$BUILD_DIR/sourcemod"

SRC="$REPO_ROOT/scripting/l4d2_invasion.sp"
INC="$REPO_ROOT/scripting/include"
OUT="$REPO_ROOT/plugins/l4d2_invasion.smx"

find_local_spcomp() {
	local base="$TOOLCHAIN/addons/sourcemod/scripting"
	for candidate in "$base/spcomp.exe" "$base/spcomp64.exe" "$base/spcomp" "$base/spcomp64"; do
		if [ -x "$candidate" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

fetch_toolchain() {
	local url file
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*) file="sourcemod-${SM_VERSION}-windows.zip" ;;
		*)                    file="sourcemod-${SM_VERSION}-linux.tar.gz" ;;
	esac
	url="https://sm.alliedmods.net/smdrop/1.12/$file"

	mkdir -p "$BUILD_DIR" "$TOOLCHAIN"
	if [ ! -s "$BUILD_DIR/$file" ]; then
		echo "==> Downloading SourceMod $SM_VERSION toolchain"
		curl -fsSL -o "$BUILD_DIR/$file" "$url"
	fi

	echo "==> Extracting $file"
	case "$file" in
		*.zip)    unzip -q -o "$BUILD_DIR/$file" -d "$TOOLCHAIN" ;;
		*.tar.gz) tar -xzf "$BUILD_DIR/$file" -C "$TOOLCHAIN" ;;
	esac
}

SPCOMP="${SPCOMP:-}"
if [ -z "$SPCOMP" ]; then
	SPCOMP="$(find_local_spcomp || true)"
fi
if [ -z "$SPCOMP" ]; then
	fetch_toolchain
	SPCOMP="$(find_local_spcomp)" || {
		echo "ERROR: could not find spcomp after extracting the toolchain." >&2
		exit 1
	}
fi

[ -f "$SRC" ] || { echo "ERROR: missing $SRC" >&2; exit 1; }
mkdir -p "$REPO_ROOT/plugins"

echo "==> spcomp: $SPCOMP"
echo "==> Compiling l4d2_invasion.sp"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! "$SPCOMP" "$SRC" -i "$INC" -o "$OUT" 2>&1 | tee "$log"; then
	echo "BUILD FAILED: spcomp returned a non-zero status." >&2
	exit 1
fi

if grep -qiE "^.*: (warning|error) [0-9]+" "$log"; then
	echo "BUILD FAILED: spcomp reported warnings or errors (zero-warning build required)." >&2
	exit 1
fi

[ -s "$OUT" ] || { echo "BUILD FAILED: $OUT was not produced." >&2; exit 1; }

echo "==> OK: $OUT"

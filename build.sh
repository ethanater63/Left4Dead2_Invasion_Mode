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

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Compile one .sp to one .smx, failing the build on any warning.
compile() {
	local src="$1" out="$2"

	echo "==> Compiling $(basename "$src")"
	if ! "$SPCOMP" "$src" -i "$INC" -o "$out" 2>&1 | tee "$log"; then
		echo "BUILD FAILED: spcomp returned a non-zero status for $(basename "$src")." >&2
		exit 1
	fi
	if grep -qiE "^.*: (warning|error) [0-9]+" "$log"; then
		echo "BUILD FAILED: spcomp reported warnings or errors (zero-warning build required)." >&2
		exit 1
	fi
	[ -s "$out" ] || { echo "BUILD FAILED: $out was not produced." >&2; exit 1; }
	echo "    OK: $out"
}

compile "$SRC" "$OUT"

# zombie_spawn_fix is the one companion plugin that ships as source only: it is
# published as an AlliedModders forum attachment (thread 333351), which sits
# behind Cloudflare and cannot be fetched by script, so the .sp and its gamedata
# live in this repo under third_party/ and we compile it here. It needs
# sourcescramble.inc, which is in scripting/include/. Skipped without failing
# the build if the source is not checked out.
ZSF_SRC="$REPO_ROOT/third_party/zombie_spawn_fix/scripting/zombie_spawn_fix.sp"
ZSF_OUT="$REPO_ROOT/plugins/zombie_spawn_fix.smx"
if [ -f "$ZSF_SRC" ]; then
	compile "$ZSF_SRC" "$ZSF_OUT"
else
	echo "==> Skipping zombie_spawn_fix (no source at third_party/)"
fi

echo "==> Build complete"

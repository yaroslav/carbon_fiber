#!/usr/bin/env bash
# Cross-compile carbon_fiber_native for one (RUBY_FULL_VERSION, RCD_PLATFORM) combo.
#
# Required env vars:
#   RUBY_FULL_VERSION   e.g. "3.4.8"
#   RUBY_API_VERSION    e.g. "3.4.0"
#   RCD_PLATFORM        e.g. "x86_64-linux-gnu"  (matches dir under RCD_BASE/)
#   TARGET_TRIPLE       e.g. "x86_64-linux-gnu"  (empty = native)
#
# Optional:
#   ZIG_VERSION         default: 0.15.2
#   RCD_BASE            default: /usr/local/rake-compiler/ruby
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
RCD_BASE="${RCD_BASE:-/usr/local/rake-compiler/ruby}"

echo "==> rcd_build: platform=${RCD_PLATFORM} ruby=${RUBY_FULL_VERSION} target=${TARGET_TRIPLE:-native}"

# ── Install Zig if missing ──────────────────────────────────────────────────
if ! command -v zig &>/dev/null; then
  # Derive OS for Zig download URL.
  case "$(uname -s)" in
    Darwin) ZIG_OS="macos" ;;
    *)      ZIG_OS="linux" ;;
  esac
  # RCD images are host-native and contain a cross-compilation toolchain for
  # ${RCD_PLATFORM}. The Zig binary we download must match the container's
  # actual architecture, not the target — `uname -m` gives us that.
  ZIG_ARCH=$(uname -m | sed 's/arm64/aarch64/')
  ZIG_DIR="${ROOT_DIR}/.zig-install/zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
  if [[ ! -d "$ZIG_DIR" ]]; then
    echo "==> Downloading Zig ${ZIG_VERSION} (${ZIG_ARCH}-${ZIG_OS})..."
    mkdir -p "$(dirname "$ZIG_DIR")"
    curl -sSfL \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.tar.xz" \
      | tar xJ -C "$(dirname "$ZIG_DIR")"
  fi
  export PATH="${ZIG_DIR}:$PATH"
fi
echo "==> zig $(zig version)"

# ── Point build/ruby.zig at the cross-compiled Ruby headers ────────────────
# RCD image layout is mostly {RCD_BASE}/{RCD_PLATFORM}/ruby-{RUBY_FULL_VERSION}/,
# but the x86_64-linux-musl image uses x86_64-unknown-linux-musl as its top
# dir. Discover by API version if the canonical path is missing.
RUBY_CROSS_DIR="${RCD_BASE}/${RCD_PLATFORM}/ruby-${RUBY_FULL_VERSION}"
if [[ ! -d "$RUBY_CROSS_DIR" ]]; then
  for alt in "${RCD_BASE}"/*/; do
    candidate="${alt}ruby-${RUBY_FULL_VERSION}"
    if [[ -d "$candidate" ]]; then
      RUBY_CROSS_DIR="$candidate"
      break
    fi
  done
fi

if [[ ! -d "$RUBY_CROSS_DIR" ]]; then
  echo "ERROR: no cross Ruby for ${RUBY_FULL_VERSION} under ${RCD_BASE}"
  echo "Available:"
  ls "${RCD_BASE}/" || true
  exit 1
fi

export RUBY_HDRDIR="${RUBY_CROSS_DIR}/include/ruby-${RUBY_API_VERSION}"
export RUBY_ARCHHDRDIR="${RUBY_CROSS_DIR}/include/ruby-${RUBY_API_VERSION}/${RCD_PLATFORM}"
export RUBY_LIBDIR="${RUBY_CROSS_DIR}/lib"
export RUBY_ARCH="${RCD_PLATFORM}"
# RUBY_API_VERSION already set by caller

echo "==> RUBY_HDRDIR=${RUBY_HDRDIR}"

# ── Build ──────────────────────────────────────────────────────────────────
cd "${ROOT_DIR}"
ZIG_ARGS=(-Doptimize=ReleaseFast)
[[ -n "${TARGET_TRIPLE:-}" ]] && ZIG_ARGS+=(-Dtarget="${TARGET_TRIPLE}")
zig build "${ZIG_ARGS[@]}"

echo "==> lib/carbon_fiber/${RUBY_API_VERSION}/carbon_fiber_native.so written"

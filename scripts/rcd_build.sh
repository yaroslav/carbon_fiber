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
  # RCD images contain a cross-compilation toolchain for ${RCD_PLATFORM}, but
  # the container itself runs on the host's architecture — not the target's.
  # `uname -m` can lie under Rosetta or QEMU (reporting the host kernel arch
  # instead of the effective container arch), so read the ELF header of a
  # binary we know executes in this environment. Whatever runs /bin/ls is
  # exactly what needs to run Zig.
  if file /bin/ls 2>/dev/null | grep -q 'x86-64'; then
    ZIG_ARCH="x86_64"
  elif file /bin/ls 2>/dev/null | grep -q 'ARM aarch64'; then
    ZIG_ARCH="aarch64"
  else
    echo "ERROR: unable to detect container architecture" >&2
    file /bin/ls >&2 || true
    exit 1
  fi
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
# RCD image layout: {RCD_BASE}/{RCD_PLATFORM}/ruby-{RUBY_FULL_VERSION}/
RUBY_CROSS_DIR="${RCD_BASE}/${RCD_PLATFORM}/ruby-${RUBY_FULL_VERSION}"

if [[ ! -d "$RUBY_CROSS_DIR" ]]; then
  echo "ERROR: no cross Ruby at ${RUBY_CROSS_DIR}"
  echo "Available:"
  ls "${RCD_BASE}/${RCD_PLATFORM}/" 2>/dev/null || ls "${RCD_BASE}/" || true
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

FROM ruby:4.0.2-bookworm

ARG ZIG_VERSION=0.15.2

ENV PATH=/opt/zig:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    curl \
    file \
    libffi-dev \
    libssl-dev \
    libyaml-dev \
    pkg-config \
    xz-utils \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" && \
    case "${arch}" in \
      amd64) zig_arch="x86_64-linux" ;; \
      arm64) zig_arch="aarch64-linux" ;; \
      *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac && \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt && \
    ln -s "/opt/zig-${zig_arch}-${ZIG_VERSION}" /opt/zig

WORKDIR /workspace

CMD ["bash"]

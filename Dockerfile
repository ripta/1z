ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends make gcc libffi-dev libc6-dev zlib1g-dev libsqlite3-dev libpcre2-dev libicu-dev && \
    rm -rf /var/lib/apt/lists/*

# Debian's libc6-dev ships /usr/lib/<triplet>/libm.so as a linker script,
# which dlopen(3) cannot use. Replace it with a real symlink to the loadable
# SONAME so bare-name `lib-open "m"` succeeds. Each apt triplet path is
# checked so the same Dockerfile works on both x86_64 and aarch64 hosts.
RUN if [ -d /usr/lib/x86_64-linux-gnu ]; then \
        ln -sf /lib/x86_64-linux-gnu/libm.so.6 /usr/lib/x86_64-linux-gnu/libm.so; \
    fi && \
    if [ -d /usr/lib/aarch64-linux-gnu ]; then \
        ln -sf /lib/aarch64-linux-gnu/libm.so.6 /usr/lib/aarch64-linux-gnu/libm.so; \
    fi

# Profiling tools used by `make aot-symbol-verify`.
# The emulator used by `make baremetal-riscv64-test`.
#
# Kept out of the runtime dependency closure so the production image stays slim;
# this RUN only matters when those harnesses run inside the build image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl linux-perf qemu-system-misc && \
    rm -rf /var/lib/apt/lists/*

ARG SAMPLY_VERSION=0.13.1
RUN case "$(uname -m)" in \
        x86_64)  triplet=x86_64-unknown-linux-gnu ;; \
        aarch64) triplet=aarch64-unknown-linux-gnu ;; \
        *) echo "samply: unsupported architecture $(uname -m)"; exit 1 ;; \
    esac && \
    curl -fL "https://github.com/mstange/samply/releases/download/samply-v${SAMPLY_VERSION}/samply-${triplet}.tar.xz" \
    | tar -xJ -C /usr/local/bin --strip-components=1 "samply-${triplet}/samply" && \
    chmod +x /usr/local/bin/samply

USER build

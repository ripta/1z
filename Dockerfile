ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends make gcc libffi-dev libc6-dev zlib1g-dev libsqlite3-dev libpcre2-dev libicu-dev && \
    rm -rf /var/lib/apt/lists/*

# Debian's libc6-dev ships /usr/lib/x86_64-linux-gnu/libm.so as a linker script,
# which dlopen(3) cannot use. Replace it with a real symlink to the loadable
# SONAME so bare-name `lib-open "m"` succeeds.
RUN ln -sf /lib/x86_64-linux-gnu/libm.so.6 /usr/lib/x86_64-linux-gnu/libm.so

USER build

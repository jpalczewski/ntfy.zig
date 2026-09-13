# Builds a fully static musl binary and ships it with no runtime at all.
FROM alpine:3.20 AS builder

RUN apk add --no-cache curl xz ca-certificates

ARG ZIG_VERSION=0.16.0
# Pin + verify against https://ziglang.org/download/index.json — check
# before bumping ZIG_VERSION.
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN /opt/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall

FROM scratch
# scratch has zero files by default — without this, the relay's outbound
# HTTPS call to ntfy has no root CAs to verify the server cert against and
# fails with TlsInitializationFailed. Confirmed live 2026-09-13.
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /src/zig-out/bin/ntfy.zig /ntfy.zig
EXPOSE 8085
# scratch has no shell/curl/wget, so the healthcheck re-execs the same
# binary in a self-check mode (see main.zig's healthcheck argv handling).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/ntfy.zig", "healthcheck"]
ENTRYPOINT ["/ntfy.zig"]

# ── Stage 1: C extensions build ───────────────────────────────────────────
FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    cmake \
    make \
    gcc \
    musl-dev \
    linux-headers

WORKDIR /build/csrc
COPY csrc/ .

RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build \
 && mkdir -p /build/artifacts \
 && find build \( -type f -o -type l \) -name '*.so*' -exec cp -L {} /build/artifacts/ \;

# ── Stage 2: Runtime ──────────────────────────────────────────────────────
FROM openresty/openresty:1.25.3.2-alpine

LABEL org.opencontainers.image.source="https://github.com/dongwonkwak/luagate"
LABEL org.opencontainers.image.description="LuaGate — OpenResty API Gateway"
LABEL org.opencontainers.image.licenses="MIT"

# Install runtime dependencies
RUN apk add --no-cache \
    curl \
    ca-certificates

# Copy C shared libraries from builder when present.
# The scaffold may not produce any modules yet, but the directory always exists.
COPY --from=builder /build/artifacts/ /usr/local/openresty/lualib/

# Copy Lua modules into a dedicated subdir — preserves bundled resty/* libs
COPY lua/luagate /usr/local/openresty/lualib/luagate/

# Copy nginx config file only
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Copy policies
COPY policies/ /etc/luagate/policies/

EXPOSE 8080 8443 9090

CMD ["openresty", "-g", "daemon off;"]

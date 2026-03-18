# ── Stage 1: Rust FFI build ──────────────────────────────────────────────
FROM rust:1.83 AS rust-builder

WORKDIR /build
COPY src/ src/

RUN cd /build/src/scanner && cargo build --release \
 && cd /build/src/decoder && cargo build --release \
 && cd /build/src/stream && cargo build --release \
 && mkdir -p /build/artifacts \
 && find /build/src -name 'libluagate_*.so' -path '*/release/*' -exec cp {} /build/artifacts/ \;

# ── Stage 1c: Dashboard UI build ──────────────────────────────────────────
FROM node:20-alpine AS ui-builder

WORKDIR /build/ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci

COPY ui/index.html ui/tsconfig.json ui/vite.config.ts ui/tailwind.config.ts ui/postcss.config.js ./
COPY ui/src/ ./src/

RUN npm run build

# ── Stage 2: Runtime ──────────────────────────────────────────────────────
FROM openresty/openresty:1.25.3.2-alpine

LABEL org.opencontainers.image.source="https://github.com/dongwonkwak/luagate"
LABEL org.opencontainers.image.description="LuaGate — OpenResty API Gateway"
LABEL org.opencontainers.image.licenses="MIT"

# Install runtime dependencies + luarocks + lyaml
RUN apk add --no-cache \
    curl \
    ca-certificates \
    gcompat \
    yaml-dev \
    luarocks5.1 \
 && apk add --no-cache --virtual .build-deps gcc musl-dev make \
 && luarocks-5.1 install lyaml YAML_DIR=/usr \
      LUA_INCDIR=/usr/local/openresty/luajit/include/luajit-2.1 \
 && apk del .build-deps

# Copy Rust FFI shared libraries
COPY --from=rust-builder /build/artifacts/ /usr/local/openresty/lualib/

# Copy Lua modules into a dedicated subdir — preserves bundled resty/* libs
COPY lua/luagate /usr/local/openresty/lualib/luagate/

# Copy nginx config file only
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Copy Dashboard UI build output
COPY --from=ui-builder /build/ui/dist/ /etc/luagate/ui/dist/

# Copy policies
COPY policies/ /etc/luagate/policies/

EXPOSE 8080 8443 9090

CMD ["openresty", "-g", "daemon off;"]

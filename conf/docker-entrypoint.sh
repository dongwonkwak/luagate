#!/bin/sh
set -eu

CONF_SRC="/usr/local/openresty/nginx/conf/nginx.conf"
CONF_RUN="/tmp/nginx-runtime.conf"

# Always copy from pristine source — idempotent across restarts.
cp "$CONF_SRC" "$CONF_RUN"

# Override admin API bind address for Docker/K8s environments where
# container-internal loopback differs from the host/pod network.
# Default nginx.conf binds to 127.0.0.1:9090 (spec-compliant).
if [ -n "${LUAGATE_ADMIN_BIND:-}" ]; then
    sed -i "s/listen 127.0.0.1:9090/listen ${LUAGATE_ADMIN_BIND}:9090/" "$CONF_RUN"
fi

# If CMD/command args are provided, execute them; otherwise start openresty.
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec openresty -c "$CONF_RUN" -g 'daemon off;'
fi

#!/bin/sh
set -eu

# Override admin API bind address for Docker/K8s environments where
# container-internal loopback differs from the host/pod network.
# Default nginx.conf binds to 127.0.0.1:9090 (spec-compliant).
if [ -n "${LUAGATE_ADMIN_BIND:-}" ]; then
    sed -i "s/listen 127.0.0.1:9090/listen ${LUAGATE_ADMIN_BIND}:9090/" \
        /usr/local/openresty/nginx/conf/nginx.conf
fi

exec openresty -g 'daemon off;'

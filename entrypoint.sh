#!/bin/sh
set -eu

# ── Required ─────────────────────────────────────────────────────────────────
: "${ORIGIN_HOST:?ERROR: ORIGIN_HOST is required}"

# ── Optional ports — empty = protocol disabled ────────────────────────────────
WS_PORT="${WS_PORT:-}"
GRPC_PORT="${GRPC_PORT:-}"
XHTTP_PORT="${XHTTP_PORT:-}"

if [ -z "$WS_PORT" ] && [ -z "$GRPC_PORT" ] && [ -z "$XHTTP_PORT" ]; then
  echo "ERROR: At least one of WS_PORT, GRPC_PORT, XHTTP_PORT must be set" >&2
  exit 1
fi

printf '════════════════════════════════════════════════════════\n'
printf '  Envoy Proxy — starting\n'
[ -n "$WS_PORT" ]    && printf '  WS    → %s:%s\n' "$ORIGIN_HOST" "$WS_PORT"
[ -n "$GRPC_PORT" ]  && printf '  gRPC  → %s:%s\n' "$ORIGIN_HOST" "$GRPC_PORT"
[ -n "$XHTTP_PORT" ] && printf '  XHTTP → %s:%s\n' "$ORIGIN_HOST" "$XHTTP_PORT"
printf '════════════════════════════════════════════════════════\n'

CONFIG=/tmp/envoy_resolved.yaml

# ── Listener + HCM header ─────────────────────────────────────────────────────
cat > "$CONFIG" << 'STATIC'
static_resources:
  listeners:
    - name: listener_8080
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 8080
      per_connection_buffer_limit_bytes: 1048576
      socket_options:
        - description: "TCP_NODELAY"
          level: 6
          name: 1
          int_value: 1
          state: STATE_LISTENING
        - description: "SO_KEEPALIVE"
          level: 1
          name: 9
          int_value: 1
          state: STATE_LISTENING
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                codec_type: AUTO
                stream_idle_timeout: 0s
                request_timeout: 0s
                upgrade_configs:
                  - upgrade_type: websocket
                access_log: []
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
                      suppress_envoy_headers: true
                route_config:
                  name: main_route
                  virtual_hosts:
                    - name: all
                      domains: ["*"]
                      routes:
STATIC

# ── Routes (only enabled protocols) ──────────────────────────────────────────
if [ -n "$GRPC_PORT" ]; then
  cat >> "$CONFIG" << 'ROUTE_GRPC'
                        - match:
                            prefix: "/"
                            headers:
                              - name: "content-type"
                                string_match:
                                  prefix: "application/grpc"
                          route:
                            cluster: xray_grpc
                            timeout: 0s
                            max_stream_duration:
                              grpc_timeout_header_max: 0s
ROUTE_GRPC
fi

if [ -n "$WS_PORT" ]; then
  cat >> "$CONFIG" << 'ROUTE_WS'
                        - match:
                            prefix: "/ws"
                          route:
                            cluster: xray_ws
                            timeout: 0s
ROUTE_WS
fi

if [ -n "$XHTTP_PORT" ]; then
  cat >> "$CONFIG" << 'ROUTE_XHTTP'
                        - match:
                            prefix: "/xhttp"
                          route:
                            cluster: xray_xhttp
                            timeout: 0s
ROUTE_XHTTP
fi

# ── Clusters header ───────────────────────────────────────────────────────────
cat >> "$CONFIG" << 'CLUSTERS_HDR'
  clusters:
CLUSTERS_HDR

# ── WS cluster ────────────────────────────────────────────────────────────────
if [ -n "$WS_PORT" ]; then
  cat >> "$CONFIG" << CLUSTER_WS
    - name: xray_ws
      connect_timeout: 3s
      type: STATIC
      per_connection_buffer_limit_bytes: 1048576
      upstream_connection_options:
        tcp_keepalive:
          keepalive_probes: 3
          keepalive_time: 30
          keepalive_interval: 5
      load_assignment:
        cluster_name: xray_ws
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: "$ORIGIN_HOST"
                      port_value: $WS_PORT
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http_protocol_options:
              enable_trailers: true
CLUSTER_WS
fi

# ── gRPC cluster ──────────────────────────────────────────────────────────────
if [ -n "$GRPC_PORT" ]; then
  cat >> "$CONFIG" << CLUSTER_GRPC
    - name: xray_grpc
      connect_timeout: 3s
      type: STATIC
      per_connection_buffer_limit_bytes: 1048576
      upstream_connection_options:
        tcp_keepalive:
          keepalive_probes: 3
          keepalive_time: 30
          keepalive_interval: 5
      load_assignment:
        cluster_name: xray_grpc
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: "$ORIGIN_HOST"
                      port_value: $GRPC_PORT
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options:
              allow_connect: true
              initial_stream_window_size: 268435456
              initial_connection_window_size: 268435456
CLUSTER_GRPC
fi

# ── XHTTP cluster ─────────────────────────────────────────────────────────────
if [ -n "$XHTTP_PORT" ]; then
  cat >> "$CONFIG" << CLUSTER_XHTTP
    - name: xray_xhttp
      connect_timeout: 3s
      type: STATIC
      per_connection_buffer_limit_bytes: 1048576
      upstream_connection_options:
        tcp_keepalive:
          keepalive_probes: 3
          keepalive_time: 30
          keepalive_interval: 5
      load_assignment:
        cluster_name: xray_xhttp
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: "$ORIGIN_HOST"
                      port_value: $XHTTP_PORT
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http_protocol_options:
              enable_trailers: true
CLUSTER_XHTTP
fi

# ── Admin ─────────────────────────────────────────────────────────────────────
cat >> "$CONFIG" << 'ADMIN'
admin:
  access_log: []
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
ADMIN

exec envoy \
  -c "$CONFIG" \
  --log-level warn \
  --log-format '[%Y-%m-%dT%T.%e][%l] %v' \
  --drain-time-s 5 \
  --drain-strategy immediate \
  "$@"

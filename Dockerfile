FROM envoyproxy/envoy:v1.29-latest

# Startup script — generates envoy config dynamically based on env vars
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Environment variables ──────────────────────────────────────────────────
# ORIGIN_HOST : Xray server IP (REQUIRED)
# WS_PORT     : WebSocket port   — empty = disabled
# GRPC_PORT   : gRPC port        — empty = disabled
# XHTTP_PORT  : SplitHTTP port   — empty = disabled
ENV ORIGIN_HOST="" \
    WS_PORT="" \
    GRPC_PORT="" \
    XHTTP_PORT=""

# Cloud Run listens on 8080
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

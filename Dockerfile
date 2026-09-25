# syntax=docker/dockerfile:1
ARG DEBIAN_TAG=12-slim
ARG UV_VERSION=0.12.19

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# ---------------------------------------------------------------- fetch
FROM debian:${DEBIAN_TAG} AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH
ARG CLAUDE_CODE_VERSION=2.1.282
ARG INTERVALS_MCP_VERSION=5.2.0
ARG BUN_VERSION=1.4.2
ARG SUPERCRONIC_VERSION=0.2.49

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq unzip \
 && rm -rf /var/lib/apt/lists/*

# Claude Code: binario nativo, verificado contra el checksum del manifest oficial.
RUN case "${TARGETARCH}" in amd64) P=linux-x64 ;; arm64) P=linux-arm64 ;; *) echo "arch no soportada: ${TARGETARCH}" >&2; exit 1 ;; esac \
 && R="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && curl -fsSL "${R}/manifest.json" -o /tmp/manifest.json \
 && SUM="$(jq -r --arg p "${P}" '.platforms[$p].checksum' /tmp/manifest.json)" \
 && curl -fsSL "${R}/${P}/claude" -o /usr/local/bin/claude \
 && echo "${SUM}  /usr/local/bin/claude" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/claude

# Bun (lo necesita el plugin de Telegram).
RUN case "${TARGETARCH}" in amd64) B=bun-linux-x64 ;; arm64) B=bun-linux-aarch64 ;; esac \
 && curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${B}.zip" -o /tmp/bun.zip \
 && unzip -q /tmp/bun.zip -d /tmp \
 && install -m 0755 "/tmp/${B}/bun" /usr/local/bin/bun

# supercronic (cron apto para contenedores), verificado por sha256.
RUN case "${TARGETARCH}" in \
      amd64) S=supercronic-linux-amd64 SUM=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
      arm64) S=supercronic-linux-arm64 SUM=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
    esac \
 && curl -fsSL "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/${S}" -o /usr/local/bin/supercronic \
 && echo "${SUM}  /usr/local/bin/supercronic" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/supercronic

# intervals-icu-mcp preinstalado y fijado: el runtime no descarga nada.
COPY --from=uv /uv /uvx /usr/local/bin/
ENV UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_PYTHON_PREFERENCE=only-managed
RUN uv tool install --python 3.12 "intervals-icu-mcp==${INTERVALS_MCP_VERSION}"

# memoria-mcp (propio), con las dependencias fijadas por su uv.lock.
COPY memoria-mcp /src/memoria-mcp
RUN uv export --project /src/memoria-mcp --frozen --no-dev --no-emit-project --no-hashes \
      -o /tmp/memoria-req.txt \
 && uv tool install --python 3.12 --constraints /tmp/memoria-req.txt /src/memoria-mcp

# -------------------------------------------------------------- runtime
FROM debian:${DEBIAN_TAG}
ARG CLAUDE_CODE_VERSION=2.1.282
ARG INTERVALS_MCP_VERSION=5.2.0
ARG BUN_VERSION=1.4.2
ARG SUPERCRONIC_VERSION=0.2.49
LABEL org.opencontainers.image.title="asistente-entrenamiento" \
      org.opencontainers.image.description="Asistente de entrenamiento por Telegram (Claude Code + Intervals.icu)" \
      org.opencontainers.image.source="https://github.com/OWNER/asistente-entrenamiento" \
      ar.asistente.claude-code="${CLAUDE_CODE_VERSION}" \
      ar.asistente.intervals-icu-mcp="${INTERVALS_MCP_VERSION}" \
      ar.asistente.bun="${BUN_VERSION}" \
      ar.asistente.supercronic="${SUPERCRONIC_VERSION}"

# git: Claude Code lo usa para clonar el marketplace de plugins.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq procps tini tmux tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1000 --shell /bin/bash asistente \
 && mkdir -p /data/claude /data/telegram /data/memoria /data/estado /data/tareas /workspace /tareas /etc/claude-code \
 && chown asistente:asistente /data/claude /data/telegram /data/memoria /data/estado /data/tareas /workspace /tareas

COPY --from=fetch /usr/local/bin/claude /usr/local/bin/bun /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/supercronic /usr/local/bin/
COPY --from=fetch /usr/local/bin/intervals-icu-mcp /usr/local/bin/memoria-mcp /usr/local/bin/control-mcp /usr/local/bin/
COPY --from=fetch /opt/uv /opt/uv

COPY rootfs/ /
COPY config/managed-settings.json /etc/claude-code/managed-settings.json
COPY config/prompts/ /opt/asistente/prompts/
COPY config/mcp.tmpl.json /opt/asistente/mcp.tmpl.json
RUN chmod 0755 /usr/local/bin/*.sh

# Nada corre como root. HOME es tmpfs en el compose (cachés descartables);
# lo persistente vive en /data/* (volúmenes nombrados).
ENV HOME=/home/asistente \
    CLAUDE_CONFIG_DIR=/data/claude \
    TELEGRAM_STATE_DIR=/data/telegram \
    MEMORIA_DIR=/data/memoria \
    ESTADO_DIR=/data/estado \
    WORKDIR=/workspace \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1 \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    BUN_INSTALL_CACHE_DIR=/tmp/bun-cache
USER 1000:1000
WORKDIR /workspace

HEALTHCHECK --interval=60s --timeout=10s --start-period=90s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]

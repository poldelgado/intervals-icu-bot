#!/usr/bin/env bash
# Valida el entorno, genera la configuración y le cede el control al supervisor.
set -euo pipefail
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

validate_common

DAILY_RESTART_TIME="${DAILY_RESTART_TIME:-04:00}"
validate_time DAILY_RESTART_TIME
export DAILY_RESTART_TIME

if [ -n "${HEALTHCHECK_URL:-}" ]; then
  [[ "${HEALTHCHECK_URL}" =~ ^https://[A-Za-z0-9._/:-]+$ ]] \
    || die "HEALTHCHECK_URL inválida (esperaba https://..., ej. https://hc-ping.com/<uuid>)"
  log "Alarma externa activada (ping cada ${HEARTBEAT_EVERY:-300}s mientras el bot esté sano)."
fi
[[ "${HEARTBEAT_EVERY:-300}" =~ ^[0-9]+$ ]] && [ "${HEARTBEAT_EVERY:-300}" -ge 60 ] \
  || die "HEARTBEAT_EVERY debe ser un entero >= 60"

/usr/local/bin/render-config.sh
exec /usr/local/bin/supervisor.sh

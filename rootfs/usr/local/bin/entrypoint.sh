#!/usr/bin/env bash
# Valida el entorno, genera la configuración y le cede el control al supervisor.
set -euo pipefail
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

validate_common

DAILY_RESTART_TIME="${DAILY_RESTART_TIME:-04:00}"
validate_time DAILY_RESTART_TIME
export DAILY_RESTART_TIME

/usr/local/bin/render-config.sh
exec /usr/local/bin/supervisor.sh

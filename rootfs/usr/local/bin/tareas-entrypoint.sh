#!/usr/bin/env bash
# Servicio `tareas`: valida, genera la configuración de solo lectura y corre supercronic.
set -euo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

validate_common

# --- Defaults y validación --------------------------------------------------------
: "${MORNING_ENABLED:=true}"       "${MORNING_TIME:=07:00}"
: "${POST_ACTIVITY_ENABLED:=true}" "${POST_ACTIVITY_EVERY_MIN:=15}"
: "${POST_ACTIVITY_DELAY_MIN:=10}" "${POST_ACTIVITY_MAX_AGE_H:=36}"
: "${ALERTS_ENABLED:=true}"        "${ALERTS_TIME:=10:00}"
: "${ALERT_RHR_DELTA:=5}"          "${ALERT_HRV_DROP_PCT:=20}" "${ALERT_TSB_MIN:=-30}"
: "${WEEKLY_ENABLED:=true}"        "${WEEKLY_DAY:=0}"          "${WEEKLY_TIME:=20:00}"
: "${MONITOR_ENABLED:=true}"       "${CHECK_TIME:=08:00}"
for v in MORNING_ENABLED POST_ACTIVITY_ENABLED ALERTS_ENABLED WEEKLY_ENABLED MONITOR_ENABLED; do
  validate_bool "$v"
done
for v in MORNING_TIME ALERTS_TIME WEEKLY_TIME CHECK_TIME; do validate_time "$v"; done
validate_int POST_ACTIVITY_EVERY_MIN 5 60
validate_int POST_ACTIVITY_DELAY_MIN 0 120
validate_int POST_ACTIVITY_MAX_AGE_H 1 168
validate_int ALERT_RHR_DELTA 1 30
validate_int ALERT_HRV_DROP_PCT 5 80
validate_int ALERT_TSB_MIN -100 0
validate_int WEEKLY_DAY 0 6
[ -z "${TAREAS_MODEL:-}" ] || [[ "${TAREAS_MODEL}" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "TAREAS_MODEL inválido: ${TAREAS_MODEL}"
export POST_ACTIVITY_DELAY_MIN POST_ACTIVITY_MAX_AGE_H ALERT_RHR_DELTA ALERT_HRV_DROP_PCT \
       ALERT_TSB_MIN

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  log "AVISO: sin CLAUDE_CODE_OAUTH_TOKEN, las tareas con Claude (matinal, actividades, semanal)" >&2
  log "       se van a saltear. Las alertas y el chequeo de la API funcionan igual." >&2
fi

# --- Directorio de trabajo SEPARADO del canal ---------------------------------------
mkdir -p "${TAREAS_WORKDIR}/.claude" "${REPORTES_DIR}" "${HOME}/.claude"
chmod 700 "${TAREAS_DATA}" "${REPORTES_DIR}"

if [ "${MEMORIA_ENABLED}" = "true" ]; then
  jq '.mcpServers |= {intervals: .intervals}
      | .mcpServers.memoria = {command: "memoria-mcp", args: [],
                               env: {MEMORIA_DIR: "${MEMORIA_DIR}", TZ: "${TZ}"}}' \
    /opt/asistente/mcp.tmpl.json > "${TAREAS_WORKDIR}/.mcp.json"
else
  jq '.mcpServers |= {intervals: .intervals}' /opt/asistente/mcp.tmpl.json > "${TAREAS_WORKDIR}/.mcp.json"
fi

# Permisos extra del proyecto: la política gestionada + denegar escrituras de memoria,
# control y Telegram (una regla deny en cualquier nivel gana sobre un allow).
jq -n --arg deny "${TAREAS_DENY}" '{permissions: {deny: ($deny | split(","))}}' \
  > "${TAREAS_WORKDIR}/.claude/settings.json"

{
  cat /opt/asistente/prompts/tareas.md
  echo
  cat /opt/asistente/prompts/comun.md
  printf '\n## Entorno\n- Zona horaria (TZ): %s\n' "${TZ:-America/Argentina/Tucuman}"
} > "${TAREAS_WORKDIR}/CLAUDE.md"

# --- Crontab ----------------------------------------------------------------------------
cron_at() { printf '%s %s' "$((10#${1#*:}))" "$((10#${1%%:*}))"; }  # HH:MM -> "M H"
crontab=/tmp/crontab
{
  echo "# Generado por tareas-entrypoint.sh (TZ=${TZ:-?})"
  [ "${MORNING_ENABLED}" = "true" ] && echo "$(cron_at "${MORNING_TIME}") * * * /usr/local/bin/tarea-matinal.sh"
  [ "${POST_ACTIVITY_ENABLED}" = "true" ] && echo "*/${POST_ACTIVITY_EVERY_MIN} * * * * /usr/local/bin/tarea-actividades.sh"
  [ "${ALERTS_ENABLED}" = "true" ] && echo "$(cron_at "${ALERTS_TIME}") * * * /usr/local/bin/tarea-alertas.sh"
  [ "${WEEKLY_ENABLED}" = "true" ] && echo "$(cron_at "${WEEKLY_TIME}") * * ${WEEKLY_DAY} /usr/local/bin/tarea-semanal.sh"
  [ "${MONITOR_ENABLED}" = "true" ] && echo "$(cron_at "${CHECK_TIME}") * * * /usr/local/bin/check-api.sh"
  true
} > "${crontab}"

log "Tareas programadas:"
grep -v '^#' "${crontab}" | sed 's/^/    /' || log "    (ninguna activada)"
supercronic -test "${crontab}" >/dev/null || die "crontab inválido"

# Chequeo inicial de la API al arrancar.
[ "${MONITOR_ENABLED}" = "false" ] || /usr/local/bin/check-api.sh || true

exec supercronic -passthrough-logs "${crontab}"

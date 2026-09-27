#!/usr/bin/env bash
# Mantiene viva la sesión de Claude Code (con el canal de Telegram) dentro de tmux.
set -uo pipefail
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

WORKDIR="${WORKDIR:-/workspace}"
MODEL_CHANGE_GRACE=20
SESSION_LOG=/tmp/claude-session.log
CHANNEL="plugin:telegram@claude-plugins-official"
PLUGIN="telegram@claude-plugins-official"

stopping=0
started_day=""
started_epoch=0
fails=0
waiting_logged=0
running_model=""
model_change_since=0
notify_model=""
poller_missing_since=0
POLLER_GRACE=180     # s tras iniciar la sesión antes de exigir el poller
POLLER_MISSING_MAX=60 # s sin poller antes de reiniciar la sesión
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-300}"   # s entre pings a HEALTHCHECK_URL
last_heartbeat=0
last_auth_notice=0
AUTH_NOTICE_EVERY=43200  # s: como mucho un aviso de token vencido cada 12 h

session_alive() { tmux has-session -t "${SESSION_NAME}" 2>/dev/null; }

stop_session() {
  session_alive || return 0
  log "Cerrando la sesión de Claude Code..."
  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -x claude >/dev/null || return 0
    sleep 1
  done
  pkill -KILL -x claude 2>/dev/null || true
}

on_term() {
  stopping=1
  log "Señal de parada recibida."
  stop_session
  exit 0
}
trap on_term TERM INT

nap() { sleep "$1" & wait $! || true; }

ensure_plugin() {
  if ! claude plugin install "${PLUGIN}" --scope user >/tmp/plugin-install.log 2>&1; then
    # Primer arranque: falta el marketplace.
    claude plugin marketplace add anthropics/claude-plugins-official >>/tmp/plugin-install.log 2>&1 || true
    claude plugin install "${PLUGIN}" --scope user >>/tmp/plugin-install.log 2>&1 || return 1
  fi
  # Preinstala las dependencias del plugin: si lo hace el propio plugin al arrancar,
  # la primera vez tarda más que el timeout de conexión de MCP y el canal queda caído.
  local dir
  dir="$(find "${CLAUDE_CONFIG_DIR}/plugins/cache/claude-plugins-official/telegram" \
           -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
  [ -n "${dir}" ] || return 1
  (cd "${dir}" && bun install --no-summary) >>/tmp/plugin-install.log 2>&1
}

start_session() {
  # Perfil de memoria actualizado en cada (re)inicio, incluido el diario.
  /usr/local/bin/render-memoria.sh || log "No pude inyectar la memoria; sigo sin ella." >&2
  : > "${SESSION_LOG}"
  running_model="$(effective_model)"
  tmux new-session -d -s "${SESSION_NAME}" -x 200 -y 50 -c "${WORKDIR}" \
    "exec claude --channels ${CHANNEL} --permission-mode dontAsk --model ${running_model}"
  tmux pipe-pane -t "${SESSION_NAME}" -o "cat >> ${SESSION_LOG}"
  started_day="$(date +%F)"
  started_epoch="$(date +%s)"
  log "Sesión '${SESSION_NAME}' iniciada (modelo: ${running_model})."
  if [ -n "${notify_model}" ]; then
    telegram_notify "✅ Listo, ahora uso ${running_model}. Arranqué una conversación nueva (lo que tengo en memoria se mantiene)." \
      || log "No pude confirmar el cambio de modelo por Telegram." >&2
    notify_model=""
  fi
}

after_exit() {
  local lived=$(( $(date +%s) - started_epoch ))
  log "La sesión terminó tras ${lived}s. Últimas líneas:"
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "${SESSION_LOG}" 2>/dev/null | grep -v '^\s*$' | tail -n 8 | sed 's/^/    | /'
  if [ "${lived}" -lt 30 ]; then
    fails=$((fails + 1))
    local delay=$(( 5 * (2 ** (fails > 6 ? 6 : fails)) ))
    [ "${delay}" -gt 300 ] && delay=300
    log "Cayó rápido (${fails} seguidas); reintento en ${delay}s."
    nap "${delay}"
  else
    fails=0
  fi
}

# Modelo elegido desde el chat (MCP control) o, si no hay, CLAUDE_MODEL del .env.
effective_model() {
  control-mcp efectivo 2>/dev/null || echo "${CLAUDE_MODEL}"
}

# Si cambió el modelo elegido, espera MODEL_CHANGE_GRACE s (para que el bot termine de
# responder) y reinicia la sesión; start_session confirma por Telegram.
check_model_change() {
  session_alive || return 0
  local wanted
  wanted="$(effective_model)"
  if [ "${wanted}" = "${running_model}" ]; then
    model_change_since=0
    return 0
  fi
  local now
  now="$(date +%s)"
  if [ "${model_change_since}" -eq 0 ]; then
    model_change_since="${now}"
    log "Cambio de modelo pedido: ${running_model} -> ${wanted} (reinicio en ${MODEL_CHANGE_GRACE}s)."
  elif [ $((now - model_change_since)) -ge "${MODEL_CHANGE_GRACE}" ]; then
    model_change_since=0
    notify_model=1
    stop_session
  fi
}

# Si el poller de Telegram desaparece (lo mató otro proceso, cayó por un error...), Claude
# sigue vivo pero el bot queda sordo. Lo detectamos y reiniciamos la sesión.
check_poller() {
  if ! session_alive; then
    poller_missing_since=0
    return 0
  fi
  local now
  now="$(date +%s)"
  [ $((now - started_epoch)) -ge "${POLLER_GRACE}" ] || return 0
  if pgrep -f '[b]un server.ts' >/dev/null; then
    poller_missing_since=0
  elif [ "${poller_missing_since}" -eq 0 ]; then
    poller_missing_since="${now}"
    log "AVISO: no veo el canal de Telegram (bun server.ts); si sigue así reinicio la sesión." >&2
  elif [ $((now - poller_missing_since)) -ge "${POLLER_MISSING_MAX}" ]; then
    log "El canal de Telegram no está corriendo hace más de ${POLLER_MISSING_MAX}s: reinicio la sesión." >&2
    poller_missing_since=0
    stop_session
  fi
}

# Alarma externa ("dead man's switch"): si está configurada HEALTHCHECK_URL (p. ej.
# healthchecks.io), la pinguea solo cuando el bot está sano de verdad (sesión + poller de
# Telegram). Si el LXC se apaga o el bot queda sordo, los pings se cortan y el servicio
# externo avisa: es la única forma de enterarse, porque un bot caído no puede avisar.
heartbeat() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  local now
  now="$(date +%s)"
  [ $((now - last_heartbeat)) -ge "${HEARTBEAT_EVERY}" ] || return 0
  session_alive && pgrep -x claude >/dev/null && pgrep -f '[b]un server.ts' >/dev/null || return 0
  # La URL contiene el identificador del check: va por stdin, no por argv.
  if printf 'url = "%s"\n' "${HEALTHCHECK_URL}" | curl -fsS -m 10 --retry 2 -o /dev/null -K -; then
    last_heartbeat="${now}"
  else
    log "AVISO: no pude pinguear HEALTHCHECK_URL (se reintenta en el próximo ciclo)." >&2
    last_heartbeat=$((now - HEARTBEAT_EVERY + 60))
  fi
}

# Si la sesión muestra un error de autenticación (token de Claude vencido o revocado),
# el bot no puede responder: avisa por Telegram con los pasos para arreglarlo.
check_auth() {
  local now
  now="$(date +%s)"
  [ $((now - last_auth_notice)) -ge "${AUTH_NOTICE_EVERY}" ] || return 0
  is_auth_error "${SESSION_LOG}" || return 0
  last_auth_notice="${now}"
  log "ERROR: la sesión muestra un error de autenticación de Claude (token vencido o revocado)." >&2
  telegram_notify "${AUTH_ERROR_MSG}" || log "No pude avisar del token vencido por Telegram." >&2
}

daily_tasks() {
  local now today
  now="$(date +%H:%M)"; today="$(date +%F)"
  if session_alive && [ "${started_day}" != "${today}" ] && [[ "${now}" > "${DAILY_RESTART_TIME}" || "${now}" == "${DAILY_RESTART_TIME}" ]]; then
    log "Reinicio diario (${DAILY_RESTART_TIME}) para limpiar el contexto."
    stop_session
  fi
}

log "Supervisor iniciado (reinicio diario ${DAILY_RESTART_TIME}, TZ=${TZ:-?})."

while [ "${stopping}" -eq 0 ]; do
  if ! has_claude_credentials; then
    if [ "${waiting_logged}" -eq 0 ]; then
      log "Sin credenciales de Claude Code. Corré scripts/setup.sh (o 'docker compose exec -it canal claude' y /login)."
      waiting_logged=1
    fi
    nap 10
    continue
  fi
  waiting_logged=0

  if ! session_alive; then
    [ "${started_epoch}" -gt 0 ] && after_exit
    if ! ensure_plugin; then
      log "No pude instalar el plugin de Telegram (¿sin red?):" >&2
      tail -n 5 /tmp/plugin-install.log | sed 's/^/    | /' >&2
      nap 30
      continue
    fi
    start_session
  fi

  daily_tasks
  check_model_change
  check_poller
  heartbeat
  check_auth
  nap 5
done

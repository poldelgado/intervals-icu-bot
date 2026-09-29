#!/usr/bin/env bash
# Funciones comunes de las tareas programadas (servicio `tareas`). Se usa con `source`.
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

TAREAS_WORKDIR="${TAREAS_WORKDIR:-/tareas}"
TAREAS_DATA="${TAREAS_DATA:-/data/tareas}"
REPORTES_DIR="${REPORTES_DIR:-${TAREAS_DATA}/reportes}"
TAREA_TIMEOUT="${TAREA_TIMEOUT:-300}"
MAX_REPORTES_GUARDADOS=60

# Tools que las tareas nunca pueden usar (además de la política gestionada):
# leer archivos, escritura de memoria, control del modelo y el canal de Telegram.
TAREAS_DENY="Read,mcp__memoria__memoria_guardar,mcp__memoria__memoria_actualizar,mcp__memoria__memoria_borrar,mcp__control,mcp__plugin_telegram_telegram"

# Modelo: TAREAS_MODEL o, si no, CLAUDE_MODEL del .env. A propósito NO sigue el /modelo del
# chat: cambiar el modelo de la conversación no encarece los reportes automáticos.
tarea_modelo() {
  printf '%s' "${TAREAS_MODEL:-${CLAUDE_MODEL:-haiku}}"
}

guardar_reporte() {  # guardar_reporte TIPO TEXTO
  mkdir -p "${REPORTES_DIR}"
  local f
  f="${REPORTES_DIR}/$(date +%Y-%m-%dT%H%M)-$1.txt"
  printf '%s\n' "$2" > "${f}"
  chmod 600 "${f}"
  # Rotación: conserva los últimos MAX_REPORTES_GUARDADOS.
  find "${REPORTES_DIR}" -maxdepth 1 -name '*.txt' -printf '%f\n' | sort -r \
    | tail -n +$((MAX_REPORTES_GUARDADOS + 1)) | while IFS= read -r viejo; do
        rm -f "${REPORTES_DIR}/${viejo}"
      done
}

# enviar_reporte TIPO TEXTO: lo guarda (para que el bot pueda responder sobre él) y lo manda.
# Con TAREAS_DRY_RUN=1 solo lo imprime (para probar sin mandar nada).
enviar_reporte() {
  # Por si el modelo usó markdown igual: Telegram (texto plano) mostraría los ** tal cual.
  set -- "$1" "$(printf '%s' "$2" | sed -e 's/\*\*//g' -e 's/__//g')"
  if [ "${TAREAS_DRY_RUN:-0}" = "1" ]; then
    printf '\n===== [prueba] reporte %s =====\n%s\n=====\n' "$1" "$2"
    return 0
  fi
  guardar_reporte "$1" "$2"
  if telegram_notify_long "$2"; then
    log "Reporte '$1' enviado ($(printf '%s' "$2" | wc -c) bytes)."
  else
    log "No pude enviar el reporte '$1' por Telegram." >&2
    return 1
  fi
}

# tarea_claude TIPO PROMPT: corre `claude -p` de solo lectura y envía el resultado.
tarea_claude() {
  local tipo="$1" prompt="$2" modelo out err rc
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "Tarea '${tipo}' salteada: las tareas necesitan CLAUDE_CODE_OAUTH_TOKEN en el .env." >&2
    return 1
  fi
  modelo="$(tarea_modelo)"
  out="$(mktemp)"; err="$(mktemp)"
  WORKDIR="${TAREAS_WORKDIR}" /usr/local/bin/render-memoria.sh >/dev/null 2>&1 || true
  log "Tarea '${tipo}' iniciada (modelo: ${modelo})."
  (
    cd "${TAREAS_WORKDIR}" || exit 1
    timeout "${TAREA_TIMEOUT}" claude -p "${prompt}" \
      --permission-mode dontAsk \
      --model "${modelo}" \
      --disallowedTools "${TAREAS_DENY}" \
      --output-format text
  ) > "${out}" 2> "${err}"
  rc=$?
  if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
    log "Tarea '${tipo}' falló (código ${rc}). Detalle:" >&2
    tail -n 5 "${err}" "${out}" 2>/dev/null | sed 's/^/    | /' >&2
    local aviso="⚠️ No pude generar el reporte automático '${tipo}' (código ${rc}). Detalle en: docker compose logs tareas"
    if is_auth_error "${err}" "${out}"; then
      log "La falla es de autenticación: el token de Claude venció o fue revocado." >&2
      aviso="${AUTH_ERROR_MSG}"
    elif [ "${rc}" -eq 124 ]; then
      aviso="⚠️ El reporte '${tipo}' tardó más de ${TAREA_TIMEOUT}s y lo corté. Si pasa seguido, subí TAREA_TIMEOUT en el .env."
    fi
    [ "${TAREAS_DRY_RUN:-0}" = "1" ] || telegram_notify "${aviso}" || true
    rm -f "${out}" "${err}"
    return 1
  fi
  enviar_reporte "${tipo}" "$(cat "${out}")"
  rc=$?
  rm -f "${out}" "${err}"
  return "${rc}"
}

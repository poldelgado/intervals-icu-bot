#!/usr/bin/env bash
# Verifica que la API de Intervals.icu responde con las credenciales configuradas.
# Si falla, avisa por Telegram. Sale con 0 si todo está bien.
set -uo pipefail
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

url="https://intervals.icu/api/v1/athlete/${INTERVALS_ICU_ATHLETE_ID}"
code="$(printf 'user = "API_KEY:%s"\n' "${INTERVALS_ICU_API_KEY}" \
  | curl -sS -m 30 -o /dev/null -w '%{http_code}' -K - "${url}" 2>/dev/null)" || code="000"

if [ "${code}" = "200" ]; then
  log "Chequeo Intervals.icu: OK"
  exit 0
fi

case "${code}" in
  401|403) why="la API key o el athlete ID fueron rechazados (HTTP ${code})" ;;
  000)     why="no hubo conexión con intervals.icu" ;;
  *)       why="respondió HTTP ${code}" ;;
esac
log "Chequeo Intervals.icu: FALLÓ - ${why}" >&2
telegram_notify "⚠️ Asistente de entrenamiento: Intervals.icu no responde bien: ${why}. Revisá INTERVALS_ICU_API_KEY / INTERVALS_ICU_ATHLETE_ID en el .env." \
  || log "No pude avisar por Telegram." >&2
exit 1

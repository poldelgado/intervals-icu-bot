#!/usr/bin/env bash
# Ejecuta una tarea programada a mano.
#   scripts/tarea.sh matinal|actividades|alertas|semanal|chequeo [--prueba]
# Con --prueba genera el reporte y lo muestra acá, sin mandarlo por Telegram ni guardarlo.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

case "${1:-}" in
  matinal|actividades|alertas|semanal) script="/usr/local/bin/tarea-$1.sh" ;;
  chequeo) script=/usr/local/bin/check-api.sh ;;
  *) echo "uso: $0 matinal|actividades|alertas|semanal|chequeo [--prueba]" >&2; exit 2 ;;
esac
dry=0
[ "${2:-}" = "--prueba" ] && dry=1
exec docker compose exec -T -e "TAREAS_DRY_RUN=${dry}" tareas "${script}"

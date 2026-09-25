#!/usr/bin/env bash
# Resumen semanal (por defecto, domingos a la noche).
set -uo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

hoy="$(date +%F)"
# Lunes de la semana actual (semana de lunes a domingo).
lunes="$(date -d "${hoy} -$(( $(date +%u) - 1 )) days" +%F)"
lunes_ant="$(date -d "${lunes} -7 days" +%F)"
domingo_ant="$(date -d "${lunes} -1 day" +%F)"

tarea_claude semanal "Hoy es $(fecha_larga "${hoy}"). Armá el RESUMEN SEMANAL de la semana del
${lunes} al ${hoy} (máximo 1500 caracteres). Arrancá con '📊 Tu semana' y las fechas. Incluí:
1. Volumen: horas, km y carga total, separado por deporte.
2. La sesión más destacada de la semana y por qué.
3. Evolución de la forma: CTL, ATL y TSB al inicio y al final de la semana.
4. Sueño promedio y FC en reposo promedio de la semana (si hay datos).
5. Comparación breve con la semana anterior (${lunes_ant} al ${domingo_ant}).
6. Dos o tres sugerencias concretas para la semana que viene, teniendo en cuenta los objetivos,
   las lesiones o molestias de la memoria y lo planificado en el calendario de Intervals.icu."

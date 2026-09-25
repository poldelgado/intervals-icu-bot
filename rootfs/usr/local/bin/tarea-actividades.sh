#!/usr/bin/env bash
# Detecta actividades nuevas en Intervals.icu (sin gastar tokens) y, cuando aparecen, pide a
# Claude un análisis y lo manda por Telegram.
#
# - Solo considera actividades que EMPEZARON hace menos de POST_ACTIVITY_MAX_AGE_H horas:
#   Intervals.icu a veces importa actividades viejas mucho después y no queremos analizarlas.
# - Espera POST_ACTIVITY_DELAY_MIN minutos desde que la ve por primera vez, para que lleguen
#   el Edge y el reloj (duplicados) y termine el análisis de Intervals.icu.
# - La primera ejecución solo marca lo existente como visto (no manda nada).
set -uo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

state="${TAREAS_DATA}/actividades.json"
max_age_h="${POST_ACTIVITY_MAX_AGE_H:-36}"
delay_s=$(( ${POST_ACTIVITY_DELAY_MIN:-10} * 60 ))
max_por_tanda=3
now="$(date +%s)"

acts="$(intervals_api "/activities?oldest=$(date -d '-3 days' +%F)&newest=$(date +%F)")" \
  || { log "Actividades: no pude consultar Intervals.icu." >&2; exit 1; }
umbral="$(date -d "-${max_age_h} hours" +%Y-%m-%dT%H:%M:%S)"

[ -s "${state}" ] || echo '{"init":false,"seen":{},"pending":{}}' > "${state}"
st="$(cat "${state}")"

guardar_estado() {
  local tmp
  tmp="$(mktemp "${TAREAS_DATA}/.actividades.XXXXXX")"
  printf '%s\n' "$1" > "${tmp}" && mv "${tmp}" "${state}"
}

if [ "$(jq -r '.init' <<< "${st}")" != "true" ]; then
  st="$(jq --argjson a "${acts}" --argjson now "${now}" \
    '.init = true | .seen = ([$a[].id | {(.): $now}] | add // {})' <<< "${st}")"
  guardar_estado "${st}"
  log "Actividades: primera ejecución, marqué $(jq '.seen | length' <<< "${st}") como vistas."
  exit 0
fi

# 1) Nuevas actividades recientes entran a "pending" con la hora en que se vieron.
# 2) Las pendientes que ya esperaron el retraso pasan a "listas".
# 3) Se purgan vistas de más de 10 días y pendientes de más de 1 día (borradas).
st="$(jq --argjson a "${acts}" --arg umbral "${umbral}" --argjson now "${now}" \
        --argjson delay "${delay_s}" --argjson max "${max_por_tanda}" '
  reduce ($a[] | select(.start_date_local >= $umbral) | .id) as $id (.;
    if .seen[$id] != null or .pending[$id] != null then . else .pending[$id] = $now end)
  | .seen    |= with_entries(select($now - .value < 864000))
  | .pending |= with_entries(select($now - .value < 86400))
  | .listas = ([.pending | to_entries[] | select($now - .value >= $delay) | .key] | .[:$max])
' <<< "${st}")" || { log "Actividades: estado inválido, lo reinicio." >&2; rm -f "${state}"; exit 1; }

listas="$(jq -c '.listas' <<< "${st}")"
# Las listas pasan a vistas pase lo que pase con el análisis (así nunca se repiten).
guardar_estado "$(jq --argjson now "${now}" '
  reduce .listas[] as $id (.; .seen[$id] = $now | del(.pending[$id])) | del(.listas)
' <<< "${st}")"

[ "${listas}" != "[]" ] || exit 0

detalle="$(jq -r --argjson ids "${listas}" \
  '.[] | select(.id as $i | $ids | index($i)) | "- \(.id): \(.name) (\(.type), inicio \(.start_date_local))"' \
  <<< "${acts}")"
log "Actividades nuevas para analizar: $(jq -r 'join(", ")' <<< "${listas}")"

tarea_claude actividad "Hoy es $(fecha_larga). Se acaban de sincronizar estas actividades en Intervals.icu:
${detalle}

Armá un ANÁLISIS POST-ACTIVIDAD (máximo 1000 caracteres). Si dos actividades son la misma sesión
(Edge y reloj al mismo tiempo), tratalas como una sola y usá la del Edge para los datos de bici.
Arrancá con un emoji según el deporte (🚴 bici, 🏃 correr, 🏋️ gimnasio, etc.) y el nombre. Incluí:
1. Qué fue: duración, distancia, desnivel.
2. Intensidad: potencia media y normalizada, IF y zonas si es bici con potencia; si no, FC y zonas.
3. Comparación breve con sesiones parecidas de las últimas 4 a 6 semanas, si hay.
4. Impacto: carga de la sesión y cómo queda la forma (TSB) hoy.
5. Una sugerencia de recuperación para lo que resta del día o mañana, teniendo en cuenta la memoria
   (lesiones, molestias, objetivos)."

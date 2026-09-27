#!/usr/bin/env bash
# Guardián de datos (sin tokens). Corre antes del resumen matinal y avisa si:
# - Alguna conexión de Intervals.icu que importa (DATA_CONNECTIONS) está caída.
# - No llegaron el sueño ni la FC en reposo de hoy (el reloj no sincronizó).
# Intervals.icu no se puede forzar a sincronizar: Garmin y Zepp le "empujan" los datos.
# Lo que sí funciona es abrir la app del celular para que el reloj/Edge sincronice.
set -uo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

hoy="$(date +%F)"
# Conexiones a vigilar (nombres de la API sin el sufijo _connected).
conexiones="${DATA_CONNECTIONS:-zepp,garmin_training}"

conns="$(intervals_api "/connections")" \
  || { log "Datos: no pude consultar las conexiones de Intervals.icu." >&2; exit 1; }
w="$(intervals_api "/wellness?oldest=${hoy}&newest=${hoy}")" \
  || { log "Datos: no pude consultar el wellness de hoy." >&2; exit 1; }

nombre() {
  case "$1" in
    zepp) echo "Zepp (Amazfit)" ;;
    garmin_training) echo "Garmin Connect (actividades del Edge)" ;;
    garmin_health) echo "Garmin Connect (salud)" ;;
    *) echo "$1" ;;
  esac
}

caidas=()
IFS=',' read -r -a lista <<< "${conexiones}"
for c in "${lista[@]}"; do
  c="${c// /}"
  [ -n "${c}" ] || continue
  # Ojo: no usar `.[$k] // "x"`: en jq, `//` trata false como ausente y una conexión
  # caída (false) pasaría por desconocida.
  v="$(jq -r --arg k "${c}_connected" 'if has($k) then (.[$k] | tostring) else "desconocida" end' <<< "${conns}")"
  if [ "${v}" = "false" ]; then
    caidas+=("$(nombre "${c}")")
  elif [ "${v}" = "desconocida" ]; then
    log "Datos: la API no informa la conexión '${c}' (revisá DATA_CONNECTIONS)." >&2
  fi
done

# ¿Llegó el wellness de hoy? Alcanza con que haya sueño o FC en reposo.
tiene_hoy="$(jq -r '(first // {}) | if ((.sleepSecs // 0) > 0 or (.restingHR // 0) > 0) then "si" else "no" end' <<< "${w}")"

msg=""
if [ "${#caidas[@]}" -gt 0 ]; then
  msg+="🔌 Se desconectó de Intervals.icu: $(printf '%s, ' "${caidas[@]}" | sed 's/, $//').
Reconectalo en Intervals.icu → Settings → Connections; mientras tanto no llegan datos nuevos."
fi
if [ "${tiene_hoy}" = "no" ]; then
  [ -z "${msg}" ] || msg+=$'\n\n'
  if [[ " ${caidas[*]} " == *"Zepp"* ]]; then
    msg+="⌚ Todavía no llegaron el sueño ni la FC en reposo de hoy (Zepp está desconectado)."
  else
    msg+="⌚ Todavía no llegaron el sueño ni la FC en reposo de hoy.
Abrí la app Zepp en el celular (con el reloj cerca) para que sincronice; en unos minutos llega a Intervals.icu."
  fi
fi

if [ -z "${msg}" ]; then
  log "Datos: todo en orden (conexiones activas y wellness de hoy presente)."
  exit 0
fi
log "Datos: faltan datos o hay conexiones caídas; aviso por Telegram."
enviar_reporte datos "${msg}"

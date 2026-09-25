#!/usr/bin/env bash
# Alertas de recuperación, calculadas sin gastar tokens:
# - FC en reposo de hoy >= promedio de los 14 días previos + ALERT_RHR_DELTA lpm (mín. 3 datos).
# - HRV de hoy <= promedio de los 14 días previos - ALERT_HRV_DROP_PCT % (si el reloj la reporta).
# - TSB de hoy (CTL - ATL) <= ALERT_TSB_MIN.
set -uo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

hoy="$(date +%F)"
w="$(intervals_api "/wellness?oldest=$(date -d '-14 days' +%F)&newest=${hoy}")" \
  || { log "Alertas: no pude consultar Intervals.icu." >&2; exit 1; }

alertas="$(jq -r --arg hoy "${hoy}" \
  --argjson drhr "${ALERT_RHR_DELTA:-5}" \
  --argjson dhrv "${ALERT_HRV_DROP_PCT:-20}" \
  --argjson tsbmin "${ALERT_TSB_MIN:--30}" '
  def prom(f): [.[] | select(.id != $hoy) | f | select(. != null and . > 0)]
               | if length >= 3 then (add / length) else null end;
  (map(select(.id == $hoy)) | first) as $t
  | if $t == null then empty else
      (prom(.restingHR)) as $rhr
    | (prom(.hrv)) as $hrv
    | ( if ($t.restingHR // 0) > 0 and $rhr != null and ($t.restingHR - $rhr) >= $drhr then
          "- FC en reposo: \($t.restingHR) lpm, +\($t.restingHR - $rhr | round) sobre tu promedio de 14 días (\($rhr | round))."
        else empty end ),
      ( if ($t.hrv // 0) > 0 and $hrv != null and ($t.hrv <= $hrv * (1 - $dhrv / 100)) then
          "- HRV: \($t.hrv | round) ms, \((1 - $t.hrv / $hrv) * 100 | round)% debajo de tu promedio (\($hrv | round))."
        else empty end ),
      ( if $t.ctl != null and $t.atl != null and ($t.ctl - $t.atl) <= $tsbmin then
          "- TSB (frescura): \($t.ctl - $t.atl | round), por debajo de \($tsbmin): mucha fatiga acumulada."
        else empty end )
    end
' <<< "${w}")" || { log "Alertas: respuesta inesperada de la API." >&2; exit 1; }

if [ -z "${alertas}" ]; then
  log "Alertas: sin novedades."
  exit 0
fi

enviar_reporte alerta "🚨 Alerta de recuperación ($(fecha_larga "${hoy}"))
${alertas}

Sugerencia: hoy tomalo suave o descansá, hidratate y priorizá el sueño. Si además tenés síntomas
(fiebre, dolor, mareos), consultá a un profesional."

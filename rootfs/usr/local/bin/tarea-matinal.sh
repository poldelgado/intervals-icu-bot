#!/usr/bin/env bash
# Resumen matinal: sueño, FC en reposo, forma, actividades de ayer, plan de hoy y recomendación.
set -uo pipefail
# shellcheck source=tareas-lib.sh
source /usr/local/bin/tareas-lib.sh

hoy="$(date +%F)"
ayer="$(date -d yesterday +%F)"

tarea_claude matinal "Hoy es $(fecha_larga "${hoy}"). Armá el RESUMEN MATINAL (máximo 1000 caracteres).
Arrancá con '☀️ Buen día' y el día de la semana. Incluí, en este orden y en pocas líneas:
1. Sueño de anoche: está en el registro de wellness de HOY (${hoy}). Duración, puntaje y calidad.
   Si HOY no hay sueño ni FC en reposo, NO uses los de otro día como si fueran de anoche: poné al
   principio '⚠️ Todavía no llegaron los datos del reloj de hoy (abrí Zepp para sincronizar)' y
   basá la recomendación en la forma, lo de ayer y la memoria.
2. FC en reposo de hoy comparada con el promedio de los 7 días anteriores (y HRV si hay).
3. Forma de hoy: CTL, ATL y TSB en una línea, con una interpretación corta.
4. Actividades de ayer (${ayer}): tipo, duración, distancia, carga y FC media.
   Si no hubo, decí 'ayer: descanso'.
5. Entrenamiento planificado para hoy en el calendario de Intervals.icu, si hay (con objetivos).
6. Nutrición del día en 1 línea: carbohidratos según la carga que toca hoy (descanso vs. salida) y
   algo concreto (ej. 'salida larga a la tarde: almuerzo con buena porción de arroz o fideos').
7. Recomendación para hoy en 1 o 2 líneas (descanso, suave, moderado o intenso), justificada con
   los datos y con lo que haya en la memoria (lesiones, molestias recientes, objetivos)."

# Troubleshooting

Primero mirá: `scripts/logs.sh` y `docker compose ps` (columna de salud).

## El contenedor sale al arrancar
Falta una variable obligatoria o tiene mal el formato: el mensaje lo dice. Corregí `.env` y `docker compose up -d`.

## "Sin credenciales de Claude Code" en el log
Todavía no hiciste el login. `scripts/setup.sh` (paso 2) o poné `CLAUDE_CODE_OAUTH_TOKEN` en `.env`.
Si el token vence (dura 1 año) o cambia tu suscripción, regeneralo con `claude setup-token`.

## El bot no responde
0. `docker compose exec canal pgrep -af '[b]un server.ts'` tiene que mostrar el poller de Telegram; si no muestra nada
   el canal está caído (reiniciá con `docker compose restart canal`).
1. `docker compose ps`: ¿está `healthy`? Si no, `scripts/logs.sh`.
2. `scripts/attach.sh`: ¿Claude Code muestra `Channels (experimental)` en el arranque? Si dice que el canal no
   está permitido o que los channels están deshabilitados, revisá tu plan: en Pro/Max no requiere nada;
   en Team/Enterprise un admin debe habilitar channels.
3. ¿Tu `TELEGRAM_USER_ID` es el correcto? Si escribís desde otra cuenta el bot te ignora en silencio (allowlist).
4. Error 409 en los logs: hay otra instancia usando el mismo token de bot (otra máquina, o el bot corriendo en otro lado).
5. `docker compose exec canal cat /data/telegram/access.json` debe mostrar `"dmPolicy": "allowlist"` y tu ID.

## Sesión trabada esperando un permiso
La sesión corre en modo `dontAsk`: lo no permitido se rechaza solo, no debería trabarse. Si igual pasa (por ejemplo un
diálogo de una versión nueva de Claude Code), conectate con `scripts/attach.sh` (salís con Ctrl+b, d), resolvelo y
avisame qué diálogo fue para agregarlo a la configuración. Un reinicio (`docker compose restart canal`) también la destraba.

## Responde que no puede usar una herramienta / dice "solo lectura" cuando no debería
Es lo esperado para escrituras. Para lecturas, mirá si el nombre de la tool cambió tras actualizar
`INTERVALS_MCP_VERSION`: comparalo con `config/managed-settings.json`.

## Datos del Amazfit que no llegan a Intervals.icu
El bot solo ve lo que hay en Intervals.icu. Verificá en Intervals.icu > Settings > Connections que Zepp/Amazfit
esté conectado, y en la pestaña Wellness que aparezcan sueño y FC en reposo. Si no aparecen ahí, el problema es la
sincronización Zepp → Intervals, no el bot.

## Actividades duplicadas (Edge + reloj)
Si grabás la misma salida con el Edge y con el Amazfit, Intervals.icu puede tener dos actividades. Configurá en
Intervals.icu (Settings > Connections y opciones de duplicados) qué fuente preferir. El asistente está instruido
para avisar y priorizar la del Edge en bici.

## "Recuerda" algo que no le dije
Mirá qué tiene guardado: preguntale "¿qué recordás de mí?" o corré `scripts/memoria.sh ver`. Borralo con
"olvidate de …" por el chat o editando el archivo (ver cabecera de `scripts/memoria.sh`). Si aparece algo que
nunca escribiste (por ejemplo texto de una actividad), es un intento de inyección: borralo y avisá.

## No recuerda lo que le dije
- `MEMORIA_ENABLED=true` en `.env` y `docker compose exec tareas bash -c 'cd /tareas && claude mcp list'` muestra `memoria ✔ Connected`.
- Cuando guarda, el bot tiene que decir "Anoté: …". Si no lo dijo, no guardó.
- El perfil tiene tope de 4 KB y el diario de 256 KB: si están llenos, el bot te va a pedir consolidar.
- El perfil se carga al iniciar la sesión; lo guardado hoy igual está disponible vía búsqueda.

## ⚠️ No corras `claude mcp list` (ni `claude` a mano) dentro del contenedor `canal` con el bot andando
Lanza una copia temporal del plugin de Telegram, y el plugin le manda SIGTERM a cualquier otro poller que encuentre:
mata el de la sesión real y el bot queda sordo (Claude vivo, sin canal). El supervisor lo detecta y reinicia la sesión
a los ~4 minutos, pero evitalo. Para chequear conexiones usá el contenedor `tareas` (no tiene el plugin de Telegram):
`docker compose exec tareas bash -c 'cd /tareas && claude mcp list'`, o `/mcp` desde `scripts/attach.sh`.

## `MCP server "intervals" connection timed out after 30000ms`
Claude Code espera 30 s a que arranque cada servidor MCP y, en equipos con disco lento (algunos LXC o VM), el
primer arranque en frío de Python lo supera: el bot responde pero sin datos de Intervals.icu. Se resuelve con
`MCP_TIMEOUT=120000` (ya es el default del compose) y `docker compose restart canal`. Verificalo con
`docker compose exec tareas bash -c 'cd /tareas && claude mcp list'`.

## `range of CPUs is from 0.01 to 1.00` al crear los contenedores
El host tiene menos núcleos que el tope configurado. Bajá `CANAL_CPUS` / `TAREAS_CPUS` en el `.env` (el máximo
es la cantidad de núcleos del host, ver `nproc`) o dale más núcleos a la VM/LXC.

## "Todavía no llegaron los datos del reloj de hoy"
Lo manda el guardián de datos (08:30) cuando Intervals.icu no tiene sueño ni FC en reposo de hoy. Intervals.icu no se
puede forzar a sincronizar: abrí la app Zepp en el celular con el reloj cerca y esperá unos minutos. Si el aviso dice
que se **desconectó** Zepp o Garmin, reconectalo en Intervals.icu → Settings → Connections.

## "El token de Claude venció o fue revocado"
Generá uno nuevo con `claude setup-token` (en una máquina con navegador), reemplazá `CLAUDE_CODE_OAUTH_TOKEN` en el `.env`
del servidor y aplicá con `docker compose up -d --force-recreate`.

## Me llegó un aviso de healthchecks.io
Los pings se cortaron: el servidor está apagado o sin internet, o el bot quedó sordo más de ~10 min. Revisá `docker compose ps`
y `scripts/logs.sh canal`. El supervisor reinicia solo la sesión si falta el canal de Telegram; si el aviso se repite, mirá
los logs.

## Mando una foto y el bot dice que no puede verla
El bot lee las fotos con permiso solo sobre `/data/telegram/inbox`. Revisá que `config/managed-settings.json` tenga
`Read(//data/telegram/inbox/**)` en `allow` y que **no** tenga `"Read"` a secas en `deny` (una regla deny a secas gana sobre
cualquier allow). Después de cambiarlo: `docker compose up -d --build --force-recreate`.

## No llegan los mensajes automáticos
- `docker compose ps`: `asistente-tareas` tiene que estar `healthy`. `scripts/logs.sh tareas` muestra las tareas
  registradas al arrancar y cada ejecución.
- ¿Está activada y a la hora que esperás? Revisá `MORNING_TIME`, `WEEKLY_DAY`, etc. y `TZ` en `.env`.
- Probala a mano sin enviar: `scripts/tarea.sh matinal --prueba`.
- Las tareas con Claude necesitan `CLAUDE_CODE_OAUTH_TOKEN` (el login con `/login` del canal no les sirve).

## No me llegó el análisis de una actividad
- Se revisa cada `POST_ACTIVITY_EVERY_MIN` minutos y se espera `POST_ACTIVITY_DELAY_MIN` más: puede tardar ~25 min.
- Solo se analizan actividades que empezaron hace menos de `POST_ACTIVITY_MAX_AGE_H` horas (evita analizar
  importaciones de actividades viejas).
- La primera vez que arranca el servicio marca todo lo existente como visto y no manda nada.
- Para re-analizar desde cero: `docker compose exec tareas rm /data/tareas/actividades.json`.

## Alertas que se repiten o que nunca llegan
Ajustá `ALERT_RHR_DELTA`, `ALERT_HRV_DROP_PCT` y `ALERT_TSB_MIN`. Con TSB muy negativo varios días seguidos, la
alerta se repite una vez por día. El Amazfit no siempre reporta HRV a Intervals.icu: en ese caso esa alerta no aplica.

## El aviso diario de "Intervals.icu no responde"
Significa 401/403 (API key o athlete ID mal o revocados), o sin conexión/HTTP 5xx. Revisá las credenciales en `.env`.

## arm64 (Raspberry Pi, Apple Silicon, Graviton)
La imagen es multi-arquitectura. En arm64 con poca RAM subí `mem_limit` (Claude Code recomienda 4 GB en el host).
Si construís en una máquina amd64 para arm64 usá `docker buildx build --platform linux/arm64`.

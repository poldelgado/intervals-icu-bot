# asistente-entrenamiento

Asistente personal de entrenamiento por Telegram. Corre Claude Code de forma persistente en un contenedor,
lee tus datos de [Intervals.icu](https://intervals.icu) (que ya unifica Garmin Edge y Amazfit) y te contesta en
español, en el celular. **Solo lectura**: no puede crear, editar ni borrar nada en Intervals.icu.

> Estado: **Fase 1** (núcleo), **Fase 1.5** (memoria) y **Fase 2** (tareas programadas). Módulos Garmin/Strava
> (Fase 3) vienen después.

## Arquitectura

```
Garmin Edge ──► Garmin Connect ──┐
                                 ├──► Intervals.icu ──► MCP (intervals-icu-mcp) ──► Claude Code ◄──► Telegram
Amazfit ──► Zepp ────────────────┘                                                 (en Docker, tmux)   (long polling)
```

- Sin puertos expuestos: Telegram funciona por *long polling* (solo tráfico saliente).
- Contenedor endurecido: usuario sin privilegios, FS raíz de solo lectura, `cap_drop: ALL`, `no-new-privileges`.
- Permisos de solo lectura en tres capas: el MCP arranca con `INTERVALS_ICU_DELETE_MODE=none`, las 33 tools de
  escritura/descarga están denegadas en `config/managed-settings.json` (política gestionada en `/etc/claude-code`,
  que el modelo no puede editar) y la sesión corre en modo `dontAsk` (lo no permitido se rechaza, no se pregunta).
  Bash, Read, Write, Edit, WebFetch y WebSearch también están denegados.
- Memoria persistente mediante un MCP propio con 5 tools acotadas (ver [Memoria](#memoria)).

## Mensajes automáticos (servicio `tareas`)

Un segundo contenedor (`tareas`, misma imagen, sin socket de Docker) corre [supercronic](https://github.com/aptible/supercronic)
y te manda por Telegram:

| Tarea | Cuándo (por defecto) | Tokens | Qué contiene |
|---|---|---|---|
| Resumen matinal | todos los días 07:00 | sí | sueño de anoche, FC en reposo vs. promedio, CTL/ATL/TSB, actividades de ayer, entrenamiento planificado de hoy y recomendación de carga |
| Análisis post-actividad | ~10–25 min después de que se sincroniza una actividad | solo si hay actividad nueva | duración, intensidad, comparación con sesiones parecidas, impacto en la forma, recuperación |
| Alertas de recuperación | todos los días 10:00, solo si algo se dispara | no | FC en reposo alta, HRV baja, TSB muy negativo |
| Resumen semanal | domingos 20:00 | sí | volumen, sesión destacada, evolución de la forma, sueño, comparación y sugerencias |
| Chequeo de la API | todos los días 08:00 | no | te avisa si Intervals.icu rechaza las credenciales |

- Las tareas con Claude corren `claude -p` en un directorio de trabajo **separado**, con los mismos permisos de solo
  lectura, sin plugins ni tools de Telegram, y la memoria montada en **solo lectura**. El mensaje sale por la Bot API.
- Usan `CLAUDE_MODEL` (o `TAREAS_MODEL`), no el modelo que elegís con `/modelo` en el chat.
- La detección de actividades nuevas consulta la API directamente (sin tokens) y solo llama a Claude cuando hay algo.
  Ignora importaciones de actividades viejas.
- Los reportes enviados se guardan (los últimos 60) para que el bot pueda responder si le preguntás por uno
  ("¿por qué me dijiste que descanse?").
- Todo se activa/desactiva y se programa desde el `.env` (ver la sección *Tareas programadas* de `.env.example`).

## Requisitos previos

- Docker con Compose v2 (Linux, macOS o Windows con Docker Desktop). Imagen amd64 y arm64.
- Cuenta de Intervals.icu con Garmin Connect y Amazfit/Zepp conectados.
- Suscripción de Claude Pro o Max. (Los *channels* de Claude Code están en *research preview*; en Team/Enterprise
  un admin debe habilitarlos.)
- Un bot de Telegram (paso 3).

## Instalación

```bash
git clone <este-repo> asistente-entrenamiento && cd asistente-entrenamiento
cp .env.example .env && chmod 600 .env     # completalo con los pasos manuales de abajo
docker compose up -d --build
scripts/setup.sh                           # guía interactiva de la primera configuración
```

`scripts/setup.sh` también hace todo lo anterior si todavía no tenés `.env`.

## Pasos manuales (en orden)

**1. Login de Claude Code (suscripción).** Dos opciones:
- **A (recomendada):** en una máquina con navegador y Claude Code instalado corré `claude setup-token`, aprobá en el
  navegador y copiá el token (dura 1 año). Pegalo en `.env` como `CLAUDE_CODE_OAUTH_TOKEN`.
- **B:** login dentro del contenedor: `docker compose exec -it canal claude`, escribí `/login`, abrí la URL, pegá el
  código que te muestre el navegador y salí con `/exit`. Queda guardado en el volumen `claude`.

> Nota de validación: la doc oficial dice que el token de `setup-token` solo permite pedidos al modelo. Que los
> *channels* funcionen con ese token hay que confirmarlo en tu primera prueba (checklist abajo). Si no funciona, usá B.

**2. API key y athlete ID de Intervals.icu.** Intervals.icu > Settings > Developer Settings > *API Key*. El athlete ID
(formato `i123456`) figura en la misma página. Van en `INTERVALS_ICU_API_KEY` e `INTERVALS_ICU_ATHLETE_ID`.

**3. Crear el bot.** En Telegram, hablá con [@BotFather](https://t.me/BotFather): `/newbot`, elegí nombre y un usuario que
termine en `bot`, copiá el token.

**4. Token del bot.** Pegalo en `TELEGRAM_BOT_TOKEN` (`.env`).

**5. Tu ID y allowlist.** Escribile a [@userinfobot](https://t.me/userinfobot) para obtener tu ID numérico y ponelo en
`TELEGRAM_USER_ID`. El contenedor siembra el allowlist (`dmPolicy: allowlist`, solo tu ID) en cada arranque, así que
**no hace falta emparejar** y el bot nunca queda abierto.

*Alternativa manual (emparejamiento):* escribile al bot, te da un código de 6 caracteres; en
`docker compose exec -it canal claude` corré `/telegram:access pair <código>` y después
`/telegram:access policy allowlist`.

Después: `docker compose up -d` (o `scripts/setup.sh`) y escribile "hola" al bot.

## Configuración (`.env`)

| Variable | Obligatoria | Default | Para qué |
|---|---|---|---|
| `INTERVALS_ICU_API_KEY`, `INTERVALS_ICU_ATHLETE_ID` | sí | | acceso a Intervals.icu |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_USER_ID` | sí | | bot y único usuario permitido |
| `CLAUDE_CODE_OAUTH_TOKEN` | no* | | login sin navegador (*o hacé login B) |
| `CLAUDE_MODEL` | no | `haiku` | modelo por defecto: `haiku` (menos cuota), `sonnet` u `opus` (más capaz). Se puede cambiar desde el chat con `/modelo` |
| `TZ` | no | `America/Argentina/Tucuman` | zona horaria (fechas relativas, reinicio, chequeo) |
| `DAILY_RESTART_TIME` | no | `04:00` | reinicio diario de la sesión (limpia contexto) |
| `MEMORIA_ENABLED` | no | `true` | memoria persistente del asistente |
| `TAREAS_MODEL`, `MORNING_*`, `POST_ACTIVITY_*`, `ALERTS_*`, `ALERT_*`, `WEEKLY_*` | no | ver `.env.example` | tareas programadas |
| `MONITOR_ENABLED`, `CHECK_TIME` | no | `true`, `08:00` | chequeo diario de la API de Intervals.icu; avisa por Telegram si falla |
| `CLAUDE_CODE_VERSION`, `INTERVALS_MCP_VERSION`, `BUN_VERSION` | no | 2.1.282 / 5.2.0 / 1.4.2 | versiones fijadas del build |

## Operación

| Tarea | Linux / macOS | Windows (PowerShell) |
|---|---|---|
| Logs (ambos, o `canal` / `tareas`) | `scripts/logs.sh [tareas]` | `docker compose logs -f --tail=100 tareas` |
| Correr una tarea ya (o probarla sin enviar) | `scripts/tarea.sh matinal [--prueba]` | `docker compose exec -e TAREAS_DRY_RUN=1 tareas /usr/local/bin/tarea-matinal.sh` |
| Conectarse a la sesión (salir: Ctrl+b, d) | `scripts/attach.sh` | `docker compose exec canal tmux attach -t claude` |
| Reiniciar | `docker compose restart canal` (o `tareas`) | igual |
| Actualizar versiones | editá versiones en `.env`, `scripts/update.sh` | `docker compose build --pull; docker compose up -d` |
| Estado / salud | `docker compose ps` | igual |
| Cambiar el modelo desde Telegram | `/modelo` (ver opciones), `/modelo sonnet`, `/modelo default` (vuelve al `.env`) | igual |
| Ver la memoria | `scripts/memoria.sh ver` | `docker compose exec canal cat /data/memoria/perfil.md /data/memoria/diario.md` |
| Exportar la memoria | `scripts/memoria.sh exportar` | `docker compose cp canal:/data/memoria/perfil.md .` (idem `diario.md`) |
| Borrar toda la memoria | `scripts/memoria.sh borrar-todo` | `docker compose exec canal rm -f /data/memoria/perfil.md /data/memoria/diario.md; docker compose restart canal` |

Los `.sh` funcionan en Linux, macOS y WSL. En Windows nativo usá los comandos de la columna derecha (o WSL).
Claude Code no se actualiza solo dentro del contenedor: para actualizar, subí la versión y reconstruí.

Respaldo, restauración y migración: [docs/backup.md](docs/backup.md).
Secretos y Docker secrets: [docs/secretos.md](docs/secretos.md).
Problemas comunes: [docs/troubleshooting.md](docs/troubleshooting.md).

## Memoria

El asistente recuerda lo que le contás por Telegram entre sesiones (la sesión se reinicia a diario).

- **Perfil** (`perfil.md`): objetivos, salud y lesiones, preferencias, equipo y referencias (FTP, FC máx.). Se
  carga completo (máx. 4 KB) al iniciar cada sesión.
- **Diario** (`diario.md`): hechos y decisiones con fecha. El asistente lo consulta cuando hace falta (máx. 256 KB).
- Todo en Markdown legible en el volumen `memoria`. Lo ves con `scripts/memoria.sh ver` o preguntando
  "¿qué recordás de mí?"; lo borrás con "olvidate de …" o `scripts/memoria.sh borrar-todo`.
- No guarda métricas que ya están en Intervals.icu (esa es la fuente de verdad).

**Seguridad.** La memoria es la única escritura que puede hacer el modelo, y solo a través de 5 tools
(`memoria_guardar`, `memoria_actualizar`, `memoria_buscar`, `memoria_listar`, `memoria_borrar`) con límites de tamaño;
no tiene acceso a archivos. El riesgo principal es la *inyección persistente*: que texto malicioso (por ejemplo el
nombre de una actividad) termine guardado y se cargue en cada sesión. Mitigaciones:
- el asistente solo guarda lo que dijiste por Telegram, y avisa cada escritura ("Anoté: …");
- todo se sanea al guardar y al inyectar (sin saltos de línea, sin `@` —que en `CLAUDE.md` importaría archivos—,
  sin encabezados ni bloques de código) y se marca como "datos, no instrucciones";
- podés auditar y borrar en cualquier momento.

Para desactivarla: `MEMORIA_ENABLED=false` y `docker compose up -d`.

## Privacidad

Tus datos de entrenamiento y salud pasan por: **Intervals.icu** (fuente), **Telegram** (tus mensajes y las respuestas)
y **Anthropic** (Claude procesa lo que consulta y lo que escribís). La memoria guarda datos personales y de salud en
el volumen `memoria` del host; incluilo en tus respaldos y protegelo como tal. Revisá sus políticas. El repo y la imagen no contienen
secretos; las variables de `.env` son visibles con `docker inspect` para quien tenga acceso al daemon.
Claude Code envía telemetría de uso según su configuración por defecto.

## Licencia de terceros

Incluye `memoria-mcp` (propio, en `memoria-mcp/`). Usa [hhopke/intervals-icu-mcp](https://github.com/hhopke/intervals-icu-mcp) y el plugin oficial de Telegram de
[anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official).

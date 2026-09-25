# Secretos

Las variables de `env_file` (`.env`) llegan al contenedor como variables de entorno. Cualquiera con acceso
al daemon de Docker del host puede verlas con `docker inspect asistente-canal`. En un PC personal o un VPS
tuyo esto suele ser aceptable; en un host compartido, no.

Mitigaciones:

- `chmod 600 .env` y no lo subas a ningún repo (ya está en `.gitignore`).
- El modelo no puede leerlas: Bash, Read, Write y Edit están denegados.
- Las credenciales de Claude Code (si usás `/login`) viven en el volumen `claude`, no en `.env`.

## Alternativa: Docker secrets (Compose)

Compose puede montar archivos como secrets en `/run/secrets/<nombre>` sin exponerlos en `docker inspect`.
El contenedor todavía no lee `*_FILE`; si lo necesitás, agregá al inicio de `entrypoint.sh`:

```bash
for v in INTERVALS_ICU_API_KEY TELEGRAM_BOT_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
  f="/run/secrets/${v,,}"
  [ -r "$f" ] && export "$v"="$(cat "$f")"
done
```

y en el compose:

```yaml
services:
  canal:
    secrets: [intervals_icu_api_key, telegram_bot_token, claude_code_oauth_token]
secrets:
  intervals_icu_api_key:   { file: ./secrets/intervals_icu_api_key }
  telegram_bot_token:      { file: ./secrets/telegram_bot_token }
  claude_code_oauth_token: { file: ./secrets/claude_code_oauth_token }
```

Ojo: el proceso de Claude Code y los MCP siguen recibiendo los valores como variables de entorno
dentro del contenedor; lo que se evita es la exposición a nivel del daemon/`inspect`.

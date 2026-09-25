# Respaldo, restauración y migración

Lo persistente vive en cinco volúmenes nombrados: `claude` (credenciales, plugins), `telegram` (allowlist),
`memoria` (perfil y diario del asistente), `estado` (modelo elegido por chat) y `tareas` (reportes enviados y
actividades ya analizadas). Compose los nombra `asistente-entrenamiento_<nombre>`.

## Respaldar

```bash
docker compose stop
mkdir -p backups
for v in claude telegram memoria estado tareas; do
  docker run --rm -v asistente-entrenamiento_$v:/d:ro -v "$PWD/backups:/b" debian:12-slim \
    tar czf /b/$v-$(date +%F).tgz -C /d .
done
docker compose start
```

Los respaldos contienen credenciales y datos personales/de salud (memoria): guardalos cifrados y fuera del repo (`backups/` está en `.gitignore`).

## Restaurar / migrar a otra máquina

1. En la máquina nueva: cloná el repo, copiá tu `.env` (por un canal seguro) y `docker compose create`.
2. Restaurá cada volumen:

```bash
for v in claude telegram memoria estado tareas; do
  docker run --rm -v asistente-entrenamiento_$v:/d -v "$PWD/backups:/b" debian:12-slim \
    sh -c "cd /d && tar xzf /b/$v-FECHA.tgz && chown -R 1000:1000 /d"
done
docker compose up -d
```

Si preferís no copiar credenciales, en la máquina nueva corré `scripts/setup.sh` de cero.

## Importante al migrar

No dejes dos instancias con el mismo token de bot corriendo a la vez: Telegram devuelve error 409
(conflicto de long polling) y ninguna funciona bien. Apagá la vieja primero.

Solo la memoria, en texto legible: `scripts/memoria.sh exportar`.

#!/usr/bin/env bash
# Sigue los logs. Sin argumentos: ambos servicios. `scripts/logs.sh tareas` o `canal`: uno solo.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
exec docker compose logs -f --tail=100 "$@"

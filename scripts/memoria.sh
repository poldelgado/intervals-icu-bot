#!/usr/bin/env bash
# Revisar, exportar o borrar la memoria del asistente.
#   scripts/memoria.sh ver           muestra perfil y diario
#   scripts/memoria.sh exportar      copia perfil.md y diario.md a backups/memoria-FECHA/
#   scripts/memoria.sh borrar-todo   vacía la memoria (pide confirmación)
# Para editar a mano: exportá, editá y copiá de vuelta con
#   docker compose cp backups/memoria-FECHA/perfil.md canal:/data/memoria/perfil.md
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

case "${1:-ver}" in
  ver)
    for f in perfil diario; do
      say "== ${f}.md =="
      in_container sh -c "cat /data/memoria/${f}.md 2>/dev/null || echo '(vacío)'"
    done
    ;;
  exportar)
    dest="backups/memoria-$(date +%F)"
    mkdir -p "${dest}"
    chmod 700 backups "${dest}"
    for f in perfil diario; do
      dc cp "${SERVICE}:/data/memoria/${f}.md" "${dest}/${f}.md" 2>/dev/null || echo "(sin ${f}.md)"
    done
    say "Exportado en ${dest}/ (contiene datos personales: guardalo con cuidado)."
    ;;
  borrar-todo)
    read -r -p "Esto borra TODA la memoria del asistente. Escribí BORRAR para confirmar: " r
    [ "${r}" = "BORRAR" ] || { echo "Cancelado."; exit 1; }
    in_container sh -c 'rm -f /data/memoria/perfil.md /data/memoria/diario.md'
    dc restart "${SERVICE}"
    say "Memoria borrada y sesión reiniciada."
    ;;
  *)
    echo "uso: $0 [ver|exportar|borrar-todo]" >&2
    exit 2
    ;;
esac

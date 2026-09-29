"""Almacén de memoria en Markdown: lógica pura, sin MCP.

Formato de cada entrada (una por línea):

    - [p-3fa9c1] 2026-09-25 · texto

perfil.md agrupa entradas bajo secciones fijas (``## objetivos``...); diario.md es una lista
plana. Las líneas que no respetan el formato se ignoran, así que editar a mano no rompe nada.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import re
import secrets
import tempfile
import unicodedata
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

CATEGORIAS = ("objetivos", "salud", "nutricion", "preferencias", "equipo", "referencias")
TIPOS = ("perfil", "diario")

MAX_TEXTO = 400
MAX_PERFIL = 4 * 1024
MAX_DIARIO = 256 * 1024
MAX_BUSCAR = 25
MAX_LISTAR_DIARIO = 30

_LINEA = re.compile(
    r"^- \[(?P<id>[pd]-[0-9a-f]{6})\] (?P<fecha>\d{4}-\d{2}-\d{2}) · (?P<texto>.+)$"
)
_SECCION = re.compile(r"^## (?P<cat>[a-z]+)\s*$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f  ]")


class MemoriaError(ValueError):
    """Error pensado para devolverle al modelo tal cual."""


@dataclass(frozen=True)
class Entrada:
    id: str
    fecha: str
    texto: str
    tipo: str
    categoria: str | None = None

    def linea(self) -> str:
        return f"- [{self.id}] {self.fecha} · {self.texto}"

    def mostrar(self) -> str:
        donde = f"perfil/{self.categoria}" if self.tipo == "perfil" else "diario"
        return f"[{self.id}] {self.fecha} ({donde}) {self.texto}"


def sanear(texto: str) -> str:
    """Deja el texto en una línea inofensiva para incrustar en CLAUDE.md.

    - sin caracteres de control ni saltos de línea;
    - ``@`` -> ``＠``: CLAUDE.md resuelve imports ``@ruta`` (recursivos);
    - sin backticks (no puede abrir bloques de código);
    - ``#`` iniciales y ``<!--`` neutralizados (no simula encabezados ni marcadores).
    """
    t = _CONTROL.sub(" ", texto)
    t = t.replace("@", "＠").replace("`", "'").replace("<!--", "< !--").replace("-->", "-- >")
    t = re.sub(r"\s+", " ", t).strip()
    t = t.lstrip("#").strip()
    return t


def _normalizar(s: str) -> str:
    s = unicodedata.normalize("NFKD", s.casefold())
    return "".join(c for c in s if not unicodedata.combining(c))


def _fecha(valor: str | None, hoy: date) -> str:
    if not valor:
        return hoy.isoformat()
    try:
        return date.fromisoformat(valor).isoformat()
    except ValueError as e:
        raise MemoriaError(f"Fecha inválida '{valor}': usá YYYY-MM-DD.") from e


class Store:
    def __init__(self, directorio: str | os.PathLike[str], hoy: date | None = None) -> None:
        self.dir = Path(directorio)
        self._hoy = hoy
        self.perfil = self.dir / "perfil.md"
        self.diario = self.dir / "diario.md"

    # ------------------------------------------------------------------ E/S
    def hoy(self) -> date:
        return self._hoy or datetime.now().astimezone().date()

    @contextlib.contextmanager
    def _lock(self) -> Iterator[None]:
        self.dir.mkdir(parents=True, exist_ok=True)
        with open(self.dir / ".lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    def _escribir(self, ruta: Path, contenido: str) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=f".{ruta.name}.")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(contenido)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, ruta)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(tmp)
            raise

    def _leer(self, ruta: Path) -> list[str]:
        try:
            return ruta.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError:
            return []

    # -------------------------------------------------------------- parseo
    def _perfil(self) -> dict[str, list[Entrada]]:
        secciones: dict[str, list[Entrada]] = {c: [] for c in CATEGORIAS}
        actual: str | None = None
        for linea in self._leer(self.perfil):
            if m := _SECCION.match(linea):
                actual = m["cat"] if m["cat"] in CATEGORIAS else None
            elif actual and (m := _LINEA.match(linea)) and m["id"].startswith("p-"):
                secciones[actual].append(
                    Entrada(m["id"], m["fecha"], sanear(m["texto"]), "perfil", actual)
                )
        return secciones

    def _diario(self) -> list[Entrada]:
        return [
            Entrada(m["id"], m["fecha"], sanear(m["texto"]), "diario")
            for linea in self._leer(self.diario)
            if (m := _LINEA.match(linea)) and m["id"].startswith("d-")
        ]

    def _todas(self) -> list[Entrada]:
        return [e for es in self._perfil().values() for e in es] + self._diario()

    @staticmethod
    def _render_perfil(secciones: dict[str, list[Entrada]]) -> str:
        partes = ["# Perfil (memoria del asistente)", ""]
        for cat in CATEGORIAS:
            partes.append(f"## {cat}")
            partes.extend(e.linea() for e in secciones[cat])
            partes.append("")
        return "\n".join(partes)

    @staticmethod
    def _render_diario(entradas: list[Entrada]) -> str:
        entradas = sorted(entradas, key=lambda e: e.fecha)
        return (
            "\n".join(["# Diario (memoria del asistente)", ""] + [e.linea() for e in entradas])
            + "\n"
        )

    def _guardar_todo(self, secciones: dict[str, list[Entrada]], diario: list[Entrada]) -> None:
        perfil_txt = self._render_perfil(secciones)
        diario_txt = self._render_diario(diario)
        if len(perfil_txt.encode()) > MAX_PERFIL:
            raise MemoriaError(
                f"El perfil superaría {MAX_PERFIL // 1024} KB. Consolidá o borrá entradas viejas "
                "(memoria_listar + memoria_actualizar/memoria_borrar) antes de agregar más."
            )
        if len(diario_txt.encode()) > MAX_DIARIO:
            raise MemoriaError(
                f"El diario superaría {MAX_DIARIO // 1024} KB. "
                "Borrá entradas viejas antes de agregar."
            )
        self._escribir(self.perfil, perfil_txt)
        self._escribir(self.diario, diario_txt)

    @staticmethod
    def _validar_texto(texto: str) -> str:
        t = sanear(texto)
        if not t:
            raise MemoriaError("El texto está vacío.")
        if len(t) > MAX_TEXTO:
            raise MemoriaError(f"Máximo {MAX_TEXTO} caracteres por entrada ({len(t)}). Resumilo.")
        return t

    def _nuevo_id(self, prefijo: str, existentes: set[str]) -> str:
        while True:
            i = f"{prefijo}-{secrets.token_hex(3)}"
            if i not in existentes:
                return i

    # -------------------------------------------------------------- API
    def guardar(
        self, tipo: str, texto: str, categoria: str | None = None, fecha: str | None = None
    ) -> Entrada:
        if tipo not in TIPOS:
            raise MemoriaError(f"tipo debe ser uno de {TIPOS}.")
        t = self._validar_texto(texto)
        f = _fecha(fecha, self.hoy())
        with self._lock():
            secciones, diario = self._perfil(), self._diario()
            ids = {e.id for es in secciones.values() for e in es} | {e.id for e in diario}
            if tipo == "perfil":
                if categoria not in CATEGORIAS:
                    raise MemoriaError(f"Para el perfil, categoria debe ser una de {CATEGORIAS}.")
                e = Entrada(self._nuevo_id("p", ids), f, t, "perfil", categoria)
                secciones[categoria].append(e)
            else:
                e = Entrada(self._nuevo_id("d", ids), f, t, "diario")
                diario.append(e)
            self._guardar_todo(secciones, diario)
        return e

    def actualizar(self, id_: str, texto: str) -> Entrada:
        t = self._validar_texto(texto)
        with self._lock():
            secciones, diario = self._perfil(), self._diario()
            for lista in [*secciones.values(), diario]:
                for i, e in enumerate(lista):
                    if e.id == id_:
                        nueva = Entrada(
                            e.id,
                            self.hoy().isoformat() if e.tipo == "perfil" else e.fecha,
                            t,
                            e.tipo,
                            e.categoria,
                        )
                        lista[i] = nueva
                        self._guardar_todo(secciones, diario)
                        return nueva
        raise MemoriaError(f"No existe la entrada {id_}.")

    def borrar(self, id_: str) -> Entrada:
        with self._lock():
            secciones, diario = self._perfil(), self._diario()
            for lista in [*secciones.values(), diario]:
                for i, e in enumerate(lista):
                    if e.id == id_:
                        del lista[i]
                        self._guardar_todo(secciones, diario)
                        return e
        raise MemoriaError(f"No existe la entrada {id_}.")

    def buscar(
        self,
        consulta: str,
        desde: str | None = None,
        hasta: str | None = None,
        limite: int = 10,
    ) -> list[Entrada]:
        terminos = [_normalizar(p) for p in consulta.split() if p.strip()]
        d = _fecha(desde, date.min) if desde else None
        h = _fecha(hasta, date.max) if hasta else None
        limite = max(1, min(limite, MAX_BUSCAR))
        res = []
        for e in self._todas():
            if d and e.fecha < d or h and e.fecha > h:
                continue
            texto = _normalizar(e.texto + " " + (e.categoria or ""))
            if all(t in texto for t in terminos):
                res.append(e)
        res.sort(key=lambda e: e.fecha, reverse=True)
        return res[:limite]

    def listar(self, tipo: str, categoria: str | None = None) -> list[Entrada]:
        if tipo == "perfil":
            secciones = self._perfil()
            if categoria and categoria not in CATEGORIAS:
                raise MemoriaError(f"categoria debe ser una de {CATEGORIAS}.")
            cats = [categoria] if categoria else list(CATEGORIAS)
            return [e for c in cats for e in secciones[c]]
        if tipo == "diario":
            return sorted(self._diario(), key=lambda e: e.fecha)[-MAX_LISTAR_DIARIO:]
        raise MemoriaError(f"tipo debe ser uno de {TIPOS}.")

    def render_perfil_para_prompt(self) -> str:
        """Bloque para incrustar en CLAUDE.md (re-saneado y truncado)."""
        secciones = self._perfil()
        lineas = []
        for cat in CATEGORIAS:
            if secciones[cat]:
                lineas.append(f"- {cat}:")
                lineas.extend(f"  - ({e.fecha}) {sanear(e.texto)}" for e in secciones[cat])
        cuerpo = "\n".join(lineas) if lineas else "- (todavía no hay nada guardado)"
        if len(cuerpo.encode()) > MAX_PERFIL:
            cuerpo = cuerpo.encode()[:MAX_PERFIL].decode(errors="ignore") + "\n- (truncado)"
        return cuerpo

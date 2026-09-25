from pathlib import Path

import pytest

from memoria_mcp import control


@pytest.fixture(autouse=True)
def entorno(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("ESTADO_DIR", str(tmp_path))
    monkeypatch.setenv("CLAUDE_MODEL", "haiku")
    return tmp_path


def test_por_defecto_usa_env() -> None:
    assert control.leer_eleccion() is None
    assert control.modelo_efectivo() == "haiku"


def test_cambiar_y_volver_a_default(entorno: Path) -> None:
    assert control.guardar_eleccion("sonnet") == "sonnet"
    assert (entorno / "modelo").read_text().strip() == "sonnet"
    assert control.guardar_eleccion("default") == "haiku"
    assert not (entorno / "modelo").exists()


def test_rechaza_modelos_invalidos(entorno: Path) -> None:
    with pytest.raises(ValueError):
        control.guardar_eleccion("gpt-5")
    (entorno / "modelo").write_text("cualquier-cosa; rm -rf /\n")
    assert control.modelo_efectivo() == "haiku"


def test_tools(entorno: Path) -> None:
    assert "Modelo actual: haiku" in control.modelo_actual()
    assert "haiku → opus" in control.modelo_cambiar("opus")
    assert "Ya estás usando opus" in control.modelo_cambiar("opus")
    assert "elegido por chat" in control.modelo_actual()


def test_reportes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    d = tmp_path / "reportes"
    monkeypatch.setenv("REPORTES_DIR", str(d))
    assert "No hay reportes" in control.reportes_recientes()
    d.mkdir()
    (d / "2026-09-24T0700-matinal.txt").write_text("Dormiste 6 h")
    (d / "2026-09-25T0700-matinal.txt").write_text("Dormiste 7 h")
    (d / "2026-09-25T1830-actividad.txt").write_text("Salida de 80 km")
    (d / "basura.txt").write_text("x")
    out = control.reportes_recientes()
    assert out.index("Salida de 80 km") < out.index("Dormiste 7 h") < out.index("Dormiste 6 h")
    assert "basura" not in out and "x\n" not in out
    solo = control.reportes_recientes("matinal", cantidad=1)
    assert "Dormiste 7 h" in solo and "Dormiste 6 h" not in solo
    (d / "2026-09-26T0700-semanal.txt").write_text("y" * 10_000)
    assert len(control.reportes_recientes("semanal")) < control.MAX_CHARS_REPORTE + 200

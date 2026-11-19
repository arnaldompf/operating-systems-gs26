"""Acesso ao banco SQLite do Alerta Córrego e regra de classificação de risco."""
import os
import sqlite3
from datetime import datetime

DB_PATH = os.environ.get("ALERTA_DB", os.path.join(os.path.dirname(__file__), "alerta.db"))

# Mesma regra usada no ESP32 (physical-computing/wokwi/sketch.ino)
NIVEL_EVACUAR = 70
NIVEL_ATENCAO = 40
CHUVA_FORTE = 30
CHUVA_MODERADA = 15


def classificar_risco(nivel_pct: float, chuva_mmh: float) -> str:
    if nivel_pct >= NIVEL_EVACUAR or (nivel_pct >= 50 and chuva_mmh >= CHUVA_FORTE):
        return "EVACUAR"
    if nivel_pct >= NIVEL_ATENCAO or chuva_mmh >= CHUVA_MODERADA:
        return "ATENCAO"
    return "NORMAL"


def conectar() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def inicializar() -> None:
    with conectar() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS leituras (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                recebido   TEXT    NOT NULL,
                estacao    TEXT    NOT NULL,
                nivel_pct  REAL    NOT NULL,
                chuva_mmh  REAL    NOT NULL,
                temp_c     REAL,
                umidade    REAL,
                risco      TEXT    NOT NULL,
                origem     TEXT    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_leituras_estacao ON leituras(estacao, id);

            -- Moradores cadastrados para alerta (DADOS FICTÍCIOS - nenhum dado real)
            CREATE TABLE IF NOT EXISTS moradores (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                estacao      TEXT NOT NULL,
                rua          TEXT NOT NULL,
                numero       TEXT NOT NULL,
                prioritario  INTEGER NOT NULL DEFAULT 0,
                necessidade  TEXT
            );
            """
        )
        if conn.execute("SELECT COUNT(*) FROM moradores").fetchone()[0] == 0:
            conn.executemany(
                "INSERT INTO moradores (estacao, rua, numero, prioritario, necessidade) VALUES (?,?,?,?,?)",
                [
                    ("corrego-01", "Rua das Palmeiras", "45", 1, "Mobilidade reduzida"),
                    ("corrego-01", "Rua das Palmeiras", "51", 0, None),
                    ("corrego-01", "Rua das Palmeiras", "60", 1, "Idoso que mora sozinho"),
                    ("corrego-01", "Travessa do Córrego", "12", 1, "Acamado"),
                    ("corrego-01", "Travessa do Córrego", "18", 0, None),
                    ("corrego-01", "Travessa do Córrego", "22", 0, None),
                    ("corrego-01", "Rua Beira-Rio", "101", 1, "Criança com deficiência"),
                    ("corrego-01", "Rua Beira-Rio", "115", 0, None),
                ],
            )


def salvar_leitura(dados: dict, origem: str) -> dict:
    nivel = float(dados["nivel_pct"])
    chuva = float(dados.get("chuva_mmh", 0))
    if not 0 <= nivel <= 100 or not 0 <= chuva <= 500:
        raise ValueError("valores fora da faixa (nivel_pct 0-100, chuva_mmh 0-500)")
    leitura = {
        "recebido": datetime.now().isoformat(timespec="seconds"),
        "estacao": str(dados.get("estacao", "corrego-01"))[:40],
        "nivel_pct": round(nivel, 1),
        "chuva_mmh": round(chuva, 1),
        "temp_c": dados.get("temp_c"),
        "umidade": dados.get("umidade"),
        "risco": classificar_risco(nivel, chuva),
        "origem": origem,
    }
    with conectar() as conn:
        conn.execute(
            "INSERT INTO leituras (recebido, estacao, nivel_pct, chuva_mmh, temp_c, umidade, risco, origem)"
            " VALUES (:recebido, :estacao, :nivel_pct, :chuva_mmh, :temp_c, :umidade, :risco, :origem)",
            leitura,
        )
    return leitura


def ultimas_leituras(limite: int = 60, estacao: str | None = None) -> list[dict]:
    sql = "SELECT * FROM leituras"
    params: tuple = ()
    if estacao:
        sql += " WHERE estacao = ?"
        params = (estacao,)
    sql += " ORDER BY id DESC LIMIT ?"
    with conectar() as conn:
        linhas = conn.execute(sql, params + (limite,)).fetchall()
    return [dict(l) for l in reversed(linhas)]


def moradores_prioritarios(estacao: str) -> list[dict]:
    with conectar() as conn:
        linhas = conn.execute(
            "SELECT rua, numero, necessidade FROM moradores WHERE estacao = ? AND prioritario = 1 ORDER BY rua, numero",
            (estacao,),
        ).fetchall()
    return [dict(l) for l in linhas]


def total_moradores(estacao: str) -> int:
    with conectar() as conn:
        return conn.execute("SELECT COUNT(*) FROM moradores WHERE estacao = ?", (estacao,)).fetchone()[0]

"""Alerta Córrego - painel web (Flask).

Rotas:
  GET  /               painel do cidadão (nível do córrego, risco, moradores prioritários)
  GET  /api/leituras   últimas leituras em JSON
  POST /api/leituras   recebe leitura por HTTP (simulador ou ESP32)
  GET  /api/status     risco atual + status da infraestrutura
  GET  /health         usado pelo healthcheck do servidor
"""
import json
import os

from flask import Flask, jsonify, render_template, request

import db

INFRA_STATUS = os.environ.get("INFRA_STATUS_FILE", "/var/lib/citizentech/infra_status.json")
ESTACAO_PADRAO = os.environ.get("ESTACAO_PADRAO", "corrego-01")

app = Flask(__name__)
db.inicializar()


def status_infra() -> dict:
    try:
        with open(INFRA_STATUS, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def resumo(estacao: str) -> dict:
    leituras = db.ultimas_leituras(60, estacao)
    atual = leituras[-1] if leituras else None
    risco = atual["risco"] if atual else "SEM_DADOS"
    return {
        "estacao": estacao,
        "atual": atual,
        "risco": risco,
        "leituras": leituras,
        "total_moradores": db.total_moradores(estacao),
        # Endereços dos prioritários só aparecem quando é preciso agir (minimização de dados)
        "prioritarios": db.moradores_prioritarios(estacao) if risco == "EVACUAR" else [],
        "qtd_prioritarios": len(db.moradores_prioritarios(estacao)),
    }


@app.get("/")
def painel():
    estacao = request.args.get("estacao", ESTACAO_PADRAO)
    return render_template("index.html", r=resumo(estacao), infra=status_infra())


@app.get("/api/leituras")
def listar():
    limite = min(int(request.args.get("limite", 60)), 500)
    return jsonify(db.ultimas_leituras(limite, request.args.get("estacao")))


@app.post("/api/leituras")
def receber():
    dados = request.get_json(silent=True) or {}
    try:
        leitura = db.salvar_leitura(dados, origem="http")
    except (KeyError, TypeError, ValueError) as e:
        return jsonify({"erro": f"leitura inválida: {e}"}), 400
    return jsonify(leitura), 201


@app.get("/api/status")
def status():
    r = resumo(request.args.get("estacao", ESTACAO_PADRAO))
    r.pop("leituras")
    r["infra"] = status_infra()
    return jsonify(r)


@app.get("/health")
def health():
    try:
        db.total_moradores(ESTACAO_PADRAO)
        return jsonify({"status": "ok"})
    except Exception as e:  # noqa: BLE001 - healthcheck deve reportar qualquer falha
        return jsonify({"status": "erro", "detalhe": str(e)}), 503


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 8000)), debug=True)

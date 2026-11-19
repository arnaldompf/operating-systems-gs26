"""Simula a estação do córrego enviando leituras por HTTP (para testes sem o Wokwi).

Uso: python3 simulador.py [URL] [segundos_entre_leituras]
     python3 simulador.py http://localhost/api/leituras 3
"""
import json
import math
import random
import sys
import time
import urllib.request

url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1/api/leituras"
intervalo = float(sys.argv[2]) if len(sys.argv) > 2 else 3

t = 0
while True:
    # Ciclo de chuva: o nível sobe até ~90% e desce de novo
    chuva = max(0.0, 45 * math.sin(t / 12) + random.uniform(-3, 3))
    nivel = min(100.0, max(5.0, 20 + 70 * max(0.0, math.sin((t - 4) / 12)) + random.uniform(-2, 2)))
    dados = {"estacao": "corrego-01", "nivel_pct": round(nivel, 1), "chuva_mmh": round(chuva, 1),
             "temp_c": round(22 + random.uniform(-1, 1), 1), "umidade": round(85 + random.uniform(-5, 5), 1)}
    req = urllib.request.Request(url, data=json.dumps(dados).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            print(resp.status, json.loads(resp.read())["risco"], dados)
    except OSError as e:
        print("erro:", e)
    t += 1
    time.sleep(intervalo)

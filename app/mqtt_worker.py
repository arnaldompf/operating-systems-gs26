"""Assina o tópico MQTT onde o ESP32 (Wokwi) publica as leituras e grava no banco."""
import json
import logging
import os
import signal
import sys

import paho.mqtt.client as mqtt

import db

BROKER = os.environ.get("MQTT_BROKER", "broker.hivemq.com")
PORTA = int(os.environ.get("MQTT_PORT", 1883))
TOPICO = os.environ.get("MQTT_TOPIC", "citizentech/alerta-corrego/+/leituras")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] mqtt_worker: %(message)s")
log = logging.getLogger()


def ao_conectar(client, _userdata, _flags, reason_code, _props):
    if reason_code.is_failure:
        log.error("Falha ao conectar no broker %s: %s", BROKER, reason_code)
        return
    log.info("Conectado em %s:%s, assinando %s", BROKER, PORTA, TOPICO)
    client.subscribe(TOPICO, qos=1)


def ao_receber(_client, _userdata, msg):
    try:
        dados = json.loads(msg.payload.decode("utf-8"))
        # O tópico traz o id da estação: citizentech/alerta-corrego/<estacao>/leituras
        dados.setdefault("estacao", msg.topic.split("/")[2])
        leitura = db.salvar_leitura(dados, origem="mqtt")
        log.info("Leitura %s: nível %.1f%% chuva %.1f mm/h -> %s",
                 leitura["estacao"], leitura["nivel_pct"], leitura["chuva_mmh"], leitura["risco"])
    except (ValueError, KeyError, TypeError, UnicodeDecodeError) as e:
        log.warning("Mensagem ignorada em %s: %s", msg.topic, e)


def main():
    db.inicializar()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"alerta-corrego-srv-{os.getpid()}")
    client.on_connect = ao_conectar
    client.on_message = ao_receber
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    signal.signal(signal.SIGTERM, lambda *_: (client.disconnect(), sys.exit(0)))
    client.connect(BROKER, PORTA, keepalive=30)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()

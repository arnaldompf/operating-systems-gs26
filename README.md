# Alerta Córrego — Infraestrutura Linux (Operating Systems)

Global Solution 2026.2 · CitizenTech · Engenharia de Software · 3º ano (Fev) · FIAP

| | |
|---|---|
| **Integrantes** | Arnaldo Filho — RM555780 · Fabricio Junior - RM555017 |
| **Vídeo de demonstração** | _(https://youtu.be/Wai1QBtXei0)_ |
| **Aplicação no ar** | http://201.23.78.192/ |

## Ficha da CitizenTech

| Campo | |
|---|---|
| **Nome** | Alerta Córrego |
| **Cidade e bairro** | São Paulo — _(bairro)_ |
| **Cidadão beneficiado** | Morador de rua às margens de córrego com risco de alagamento, com prioridade para idosos e pessoas com mobilidade reduzida |
| **Problema, em uma frase** | Moradores de ruas às margens de córregos pequenos recebem o alerta de chuva da Defesa Civil para a região inteira, mas não sabem quando o córrego da rua deles vai transbordar, e quem tem mobilidade reduzida depende de vizinhos para sair a tempo. |
| **Como funciona** | Um ESP32 no córrego mede o nível da água e a chuva e publica via MQTT. Este servidor Linux recebe as leituras, classifica o risco (Normal / Atenção / Evacuar) e mostra um painel web com a rede de apoio aos moradores prioritários. |
| **Diferencial** | Complementa a Defesa Civil: o alerta oficial avisa que vai chover na região; o Alerta Córrego avisa que a água está subindo **naquela rua** e quem precisa de ajuda primeiro. |
| **Indicador de impacto** | Minutos de antecedência entre o alerta e o transbordamento; nº de moradores prioritários alertados |
| **ODS** | 11 (cidades resilientes, meta 11.5) · 13 (adaptação ao clima, meta 13.1) · 10 (inclusão de idosos e PcD) |

---

## A solução

Um servidor **Ubuntu 24.04** provisionado do zero, **automaticamente e por Shell Script**, que hospeda a aplicação web do Alerta Córrego com monitoramento, tolerância a falhas e trilha de auditoria.

```
                 Internet                         VM Ubuntu 24.04 (alerta-corrego-srv01)
 ┌──────────┐   MQTT    ┌──────────────┐   ┌──────────────────────────────────────────────────┐
 │ ESP32    │ ────────► │ broker MQTT  │ ◄─┤ alerta-corrego-mqtt.service (assina o tópico)     │
 │ (Wokwi)  │           │ (HiveMQ)     │   │            │ grava                                │
 └──────────┘           └──────────────┘   │            ▼                                      │
                                           │      SQLite /var/lib/alerta-corrego               │
 ┌──────────┐  HTTP :80                    │            ▲                                      │
 │ Cidadão  │ ───────► ufw ──► nginx ──────┼─► alerta-corrego.service (gunicorn + Flask)     │
 └──────────┘                              │      escuta só em app.alertacorrego.local         │
                                           │      = 10.50.0.10:8000 (interface interna citz0)  │
                                           │                                                   │
                                           │ citizentech-monitor.service   (CPU / MEM / DISCO) │
                                           │ citizentech-healthcheck.timer (a cada 1 min)      │
                                           │ auditd + /var/log/citizentech/*.log               │
                                           └──────────────────────────────────────────────────┘
```

## Como executar

Em uma VM Ubuntu 24.04, com um usuário que tenha sudo:

```bash
git clone <URL-DO-REPOSITORIO>
cd <repositorio>/operating-systems
sudo ./provision.sh
```

Em cerca de 2 minutos a aplicação fica disponível em `http://<IP-da-VM>/`. Toda a configuração (hostname, IPs, DNS, portas, limites de alerta) fica em um único arquivo: [config/citizentech.env](config/citizentech.env).

| Comando | O que faz |
|---|---|
| `sudo ./provision.sh` | Executa as 4 etapas em ordem |
| `sudo ./provision.sh 2` | Executa só uma etapa (ex.: reimplantar a aplicação) |
| `./scripts/status.sh` | Visão geral: rede, serviços, métricas, alertas e risco atual |
| `sudo ./scripts/teste_falha.sh [app\|monitor\|cpu\|memoria\|disco\|todos]` | Simula falhas e mostra a recuperação |
| `sudo /opt/citizentech/bin/relatorio_auditoria.sh` | Relatório consolidado de auditoria |
| `python3 app/simulador.py http://<IP>/api/leituras` | Envia leituras simuladas, sem o ESP32 |

Todos os scripts são **idempotentes**: executar de novo não quebra nada, só reaplica a configuração (segunda execução do `provision.sh` na VM: 37 s, sem erros).

## Scripts e critérios de avaliação

### 1. Provisionamento de infraestrutura (rede, DNS, IP) — [scripts/01_infra.sh](scripts/01_infra.sh)
- **Hostname** `alerta-corrego-srv01` com FQDN, e `preserve_hostname` para o cloud-init não desfazer no reboot. Fuso `America/Sao_Paulo`.
- **IP:** cria a **rede interna da aplicação**, a interface `citz0` com IP estático `10.50.0.10/24` (systemd-networkd, persiste no boot). A interface pública continua em DHCP de propósito: a VM é de nuvem, e trocar o IP dela derrubaria o acesso SSH.
- **DNS:** `/etc/hosts` resolve `app.alertacorrego.local → 10.50.0.10` (nome usado pelo nginx); systemd-resolved configurado com 1.1.1.1 e 8.8.8.8, com **rollback automático** se a resolução falhar.
- **Firewall (ufw):** nega tudo por padrão e libera só as portas 22 e 80; a porta 8000 da aplicação não fica exposta.

### 2. Provisionamento da aplicação — [scripts/02_app.sh](scripts/02_app.sh)
- Dependências (Python 3, venv, nginx, SQLite) e **usuário de sistema sem login** `citizentech`.
- Código em `/opt/citizentech/alerta-corrego`, ambiente virtual com versões fixas ([app/requirements.txt](app/requirements.txt)) e variáveis de ambiente em `/etc/citizentech/app.env`.
- **Orquestração com systemd:** `alerta-corrego.service` (web) e `alerta-corrego-mqtt.service` (receptor do ESP32), com `Restart=always` e endurecimento (`ProtectSystem=strict`, `NoNewPrivileges`).
- **nginx** como proxy reverso (porta 80 → rede interna), com página amigável enquanto a aplicação reinicia.
- Rotação de logs (logrotate) e verificação final de saúde.

### 3. Monitoramento com alertas de CPU, Disco e Memória — [bin/monitor.sh](bin/monitor.sh)
- A cada 15 s mede CPU (`/proc/stat`), memória (`MemAvailable`) e disco (`df`) e grava em `metricas.log`.
- Acima do limite (80% / 80% / 85%, configurável) gera **ALERTA** em `alertas.log` e no journald, informando **o processo que mais consome**; quando normaliza, registra **RECUPERADO**. Um intervalo mínimo evita repetir o mesmo alerta.
- Também alerta se algum serviço da aplicação parar e publica o estado em JSON, exibido no painel web.

### 4. Monitoramento como serviço tolerante a falhas — [config/systemd/](config/systemd/)
- `citizentech-monitor.service`: `Restart=always` + **watchdog** (`WatchdogSec=60`). O script avisa o systemd a cada ciclo; se travar, o systemd o reinicia.
- `OnFailure=citizentech-falha@%n.service`: toda falha de serviço vira registro em `alertas.log`.
- `citizentech-healthcheck.timer`: a cada minuto testa a aplicação; se ela não responder, reinicia e registra.

### 5. Logs de auditoria e execução — [scripts/lib_log.sh](scripts/lib_log.sh), [config/audit/citizentech.rules](config/audit/citizentech.rules)
- Toda execução de script grava em `/var/log/citizentech/audit.log`: **quem** executou (o usuário real por trás do sudo), **quando**, argumentos, **resultado** e código de saída. Cada script tem também seu próprio log detalhado.
- **auditd** com 14 regras: alterações na aplicação, configurações, rede/DNS/hostname, firewall, sudoers, execução dos scripts e **processos mortos com `kill -9`**.
- [bin/relatorio_auditoria.sh](bin/relatorio_auditoria.sh) consolida tudo em um relatório.

### 6. Funcionamento completo
Provisionamento completo na VM em 100 s, sem erros; leituras MQTT chegando ao painel; todos os cenários do teste de falha aprovados (abaixo).

## Teste de falha (execução real na VM)

`sudo ./scripts/teste_falha.sh todos` — saída completa em [evidencias/teste_falha.txt](evidencias/teste_falha.txt).

| Cenário | O que o script faz | Resultado |
|---|---|---|
| `app` | `kill -9` no gunicorn | systemd reiniciou a aplicação em **3,1 s**; painel voltou a responder |
| `monitor` | `kill -9` no próprio monitor | systemd reiniciou em **5,1 s** |
| `cpu` | `stress-ng` a 100% em todos os núcleos | `ALERTA CPU em 94% - maior consumo: stress-ng-cpu` → `RECUPERADO` |
| `memoria` | aloca memória até passar do limite | `ALERTA MEMORIA em 89%` → `RECUPERADO` |
| `disco` | `fallocate` até passar de 85% | `ALERTA DISCO em 89%` → arquivo removido → `RECUPERADO` |

## Evidências

| Arquivo | Conteúdo |
|---|---|
| [evidencias/teste_falha.txt](evidencias/teste_falha.txt) | Saída do teste de falha completo |
| [evidencias/alertas.log](evidencias/alertas.log) | Alertas e recuperações gerados pelo monitor, healthcheck e systemd |
| [evidencias/metricas.log](evidencias/metricas.log) | Série de CPU;MEM;DISCO (com os picos do teste) |
| [evidencias/audit_execucao_scripts.log](evidencias/audit_execucao_scripts.log) | Execuções dos scripts: quem, quando e resultado. As primeiras linhas estão em UTC e com o hostname original (`gs-fiap1`) porque o próprio `01_infra.sh` troca o fuso e o hostname durante a execução |
| [evidencias/relatorio_auditoria.txt](evidencias/relatorio_auditoria.txt) | Relatório consolidado, com os eventos do auditd (alterações de rede/DNS/firewall e os `kill -9` do teste) |
| [evidencias/status_servidor.txt](evidencias/status_servidor.txt) | Estado da rede, DNS, firewall, `/etc/hosts` e serviços |

## Logs no servidor

| Arquivo | Conteúdo |
|---|---|
| `/var/log/citizentech/audit.log` | Execução de cada script (quem, quando, resultado) |
| `/var/log/citizentech/alertas.log` | Alertas e recuperações (CPU, memória, disco, serviços, healthcheck, systemd) |
| `/var/log/citizentech/metricas.log` | Série histórica CPU;MEM;DISCO |
| `/var/log/citizentech/<script>.log` | Log detalhado de cada script |
| `/var/log/citizentech/app/`, `nginx-*.log` | Acessos e erros da aplicação |
| `/var/log/audit/audit.log` | auditd (consulta: `ausearch -k citizentech_<chave> --format text`) |

## Estrutura

```
operating-systems/
├── provision.sh              # orquestrador: executa as 4 etapas
├── scripts/                  # 01_infra, 02_app, 03_monitoramento, 04_auditoria, teste_falha, status, lib_log
├── bin/                      # instalados em /opt/citizentech/bin: monitor, healthcheck, auditoria
├── config/                   # citizentech.env, units systemd, nginx, regras auditd, logrotate
├── app/                      # aplicação web Flask + receptor MQTT + simulador
└── evidencias/               # saídas reais da VM
```

## Dados

Nenhum dado pessoal real. Os moradores cadastrados no banco são fictícios e aparecem apenas como endereço e tipo de necessidade, **somente** quando o risco é EVACUAR (minimização de dados).

Uso de IA registrado em [../prompts.md](../prompts.md).

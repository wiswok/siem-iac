# Modelo de Seguridad y Capacidades de Detección

## Modelo de Amenazas

La plataforma está diseñada para detectar y responder ante las siguientes categorías de amenazas en un entorno de infraestructura Linux con servicios containerizados:

### Amenazas a nivel de host (HIDS — Wazuh)

| Amenaza | Detección | Reglas Wazuh |
|:---|:---|:---|
| Acceso no autorizado (brute force SSH) | Correlación de `authentication_failed` por IP origen | 5710 (agregada por `wazuh_brute_force` en ElastAlert2) |
| Escalada de privilegios | Intentos de sudo fallidos | 5401, 5402 |
| Modificación de ficheros críticos | File Integrity Monitoring (FIM/syscheck) | 550-554 |
| Rootkits | Rootcheck (ficheros, troyanos, puertos ocultos) | 510-516 |
| Vulnerabilidades conocidas | Vulnerability Detector (feeds NVD/Canonical) | 23502 (Solved), 23503-23506 (Low→Critical) |
| Instalación/eliminación de paquetes | Monitorización de `dpkg.log` | 2902-2904 |
| Puertos abiertos sospechosos | Comando `netstat` periódico | 533 |
| Disco lleno | Comando `df -P` periódico | 531 |
| Pérdida de visibilidad de un agente | Evento `agent_disconnect` del manager | wazuh_agente_desconectado (ElastAlert2) |

### Amenazas a nivel de red (NIDS — Suricata)

| Amenaza | Detección | Ruleset |
|:---|:---|:---|
| Exploits de red | Firmas ET Open | Severity 1 |
| Malware / C2 | Firmas de C2 y troyanos | Categoría "A Network Trojan was detected" |
| Escaneo de puertos | Detección de patrones de escaneo | Categoría "Attempted Information Leak" |
| Web Application Attacks | SQLi, XSS, path traversal | Categoría "Web Application Attack" |
| Anomalías de protocolo | Detección de protocolo malformado | Categorías varias |

> Cobertura limitada al tráfico que atraviesa la interfaz virtual de la VM `ids-core`. El laboratorio no dispone de puerto SPAN físico (NUC con una sola NIC). Línea futura: sonda NIDS física con port mirroring.

### Amenazas operacionales (Observabilidad — Prometheus)

| Amenaza | Detección | Alerta |
|:---|:---|:---|
| Nodo caído | `up == 0` durante 2 min | Alertmanager → Telegram `[INFRA]` |
| Disco > 85 % | Filesystem usage | Alertmanager → Telegram `[INFRA]` |
| CPU sostenida > 90 % | Node Exporter | Alertmanager → Telegram `[INFRA]` |
| Certificado próximo a caducar (< 6 h) | Blackbox `probe_ssl_earliest_cert_expiry` | Alertmanager → Telegram `[INFRA]` |
| Servicio crítico no responde (sonda) | Blackbox HTTP/TCP fallida 2 min | Alertmanager → Telegram `[INFRA]` |

## Reglas de correlación ElastAlert2

**8 reglas** que consultan los índices de Elasticsearch y envían a Telegram con prefijo `[SIEM]`:

| Regla | Tipo | Disparador |
|:---|:---|:---|
| `wazuh_critica` | `any` | Alertas Wazuh con `rule.level >= 12` excluyendo `vulnerability-detector` |
| `wazuh_brute_force` | `frequency` | ≥ 5 `authentication_failed` (rule 5710) por IP en 5 min |
| `wazuh_fim` | `any` | Cambios FIM `rule.level >= 7`, deduplicación por `(agent, syscheck.path)` |
| `wazuh_vuln_nuevo` | `new_term` | Primera vez que se observa una pareja `(cve, agent.name)` |
| `wazuh_vuln_resuelto` | `flatline` | Una pareja `(cve, agent)` deja de aparecer durante ~2 × intervalo de scan |
| `wazuh_agente_desconectado` | `any` | Evento `agent_disconnect` emitido por el manager |
| `suricata_critica` | `any` | Alertas Suricata `severity: 1` o categorías maliciosas (Trojan, Malware C2, Exploit Kit, Web Application Attack) |
| `suricata_anomalia` | `frequency` | Agrupación de alertas Suricata por IP origen sobre umbral |

> La estrategia de clasificación (estado continuo / hallazgo persistente / evento puntual) y la lógica detrás de cada `query_key` y `realert` están documentadas en [ADR-012](decisions.md#adr-012-alertas-clasificadas-en-tres-categorías-por-naturaleza-temporal).

## Mapeo MITRE ATT&CK

| Táctica | Técnica | Detección en la plataforma |
|:---|:---|:---|
| **Initial Access** | T1110 Brute Force | Wazuh regla 5710 + Active Response |
| **Execution** | T1059 Command-Line Interface | Logs de auth + syslog |
| **Persistence** | T1098 Account Manipulation | FIM sobre `/etc/passwd`, `/etc/shadow` |
| **Privilege Escalation** | T1548 Abuse Elevation Control | Wazuh regla 5401 (sudo fail) |
| **Defense Evasion** | T1014 Rootkit | Wazuh rootcheck |
| **Discovery** | T1046 Network Service Scanning | Suricata (port scan detection) |
| **Lateral Movement** | T1021 Remote Services | Correlación de SSH entre agentes |
| **Collection** | T1005 Data from Local System | FIM sobre directorios críticos |
| **Exfiltration** | T1041 Exfiltration Over C2 | Suricata firmas de C2 |
| **Impact** | T1485 Data Destruction | FIM alertas de borrado |

## Respuesta Activa

Wazuh bloquea automáticamente las IPs atacantes mediante `firewall-drop` (iptables):

```
Brute force SSH detectado (rule 5710 agrupada)
        │
        ▼
Wazuh Manager dispara Active Response
        │
        ▼
Agente local ejecuta iptables -A INPUT -s <ip> -j DROP
        │
        ▼
Timeout 30 min → desbloqueo automático
```

### Whitelist implícita

La red interna `10.10.0.0/16` está en whitelist en la configuración global de Wazuh (`ossec.conf → global → white_list`) para evitar auto-bloqueo entre nodos.

Detalle de la decisión y alternativas en [ADR-009](decisions.md#adr-009-active-response-con-firewall-drop-iptables).

## Tuning de Falsos Positivos

### FIM (syscheck)

Ignores configurados para reducir el ruido operacional sin comprometer la seguridad:

| Patrón ignorado | Razón |
|:---|:---|
| `/boot/*` | Kernel/GRUB se reescriben en cada `apt upgrade` |
| `/etc/ld.so.cache` | Regenerado por `ldconfig` tras cada `apt install` |
| `/etc/systemd/system/*snap*` | Snap reescribe unit-files en cada refresh |
| `/var/lib/apt`, `/var/lib/dpkg` | Caches de paquetes sin valor forense |
| `/var/lib/docker/*`, `/var/lib/containerd/*` | Runtime de contenedores |
| `/var/cache`, `/var/log`, `/tmp`, `/run` | Estado runtime transitorio |

### Wazuh decoder events

Los eventos de decoder de Suricata se silencian a nivel de regla Wazuh para evitar duplicación con los eventos nativos de Suricata ingestados por Filebeat.

### Vulnerability Detector

- `syscollector` cada ~10 min (compromiso entre reactividad y carga).
- `vulnerability-detector` feed update cada 1-6 h (la respuesta a un CVE ocurre en días, no en minutos).
- Reglas `wazuh_critica` y `wazuh_brute_force` filtran explícitamente `NOT rule.groups: vulnerability-detector` para que los CVEs viajen por su flujo dedicado (apertura + cierre) y no contaminen las alertas críticas.

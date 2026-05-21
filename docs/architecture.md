# Arquitectura de la Plataforma SIEMaaS

## Visión General

La plataforma sigue un modelo de **seguridad distribuida** donde cada nodo tiene un rol especializado:

- **sec-core:** Motor de seguridad central — procesa, almacena y correlaciona todos los eventos.
- **ids-core:** Sensor de red — captura tráfico y genera alertas de intrusión.
- **obs-core:** Observabilidad — monitoriza la salud de todos los nodos de la plataforma.
- **edge-core:** Perímetro interno — gestiona identidad (PKI) y punto de entrada TLS unificado.
- **gitlab-core:** DevSecOps — repositorio de código y pipeline CI/CD (host preexistente, no provisionado por Terraform).

## Hardware

| Nodo físico (Intel NUC) | CPU | RAM | Almacenamiento | VMs alojadas |
|---|---|---|---|---|
| **pve1** | i3 12ª gen | 32 GB | 256 GB SSD + 1 TB NVMe | `sec-core` |
| **pve2** | i5 11ª gen | 64 GB | 256 GB SSD + 1 TB NVMe | `obs-core`, `edge-core` |
| **pve3** | i7 12ª gen | 64 GB | 256 GB SSD + 1 TB NVMe | `ids-core`, `gitlab-core` |

Red gestionada por una **UniFi Dream Machine Pro**: enrutamiento inter-VLAN, NAT saliente, DNS interno `*.lab.wiswok.net` y motor IDS/IPS con políticas granulares de firewall.

## Stack tecnológico con versiones

| Capa | Componente | Versión |
|---|---|---|
| Hipervisor | Proxmox VE | 8.x |
| Provisión | Terraform (`bpg/proxmox`) | 1.9+ |
| Configuración | Ansible | 2.17+ |
| Contenedores | Docker Engine | latest stable |
| Reverse proxy | Traefik | 3.1 |
| PKI interna | Smallstep step-ca | latest |
| SIEM core | Elastic Stack (ES + Kibana + Logstash) | 8.14.3 |
| HIDS | Wazuh Manager + Agent | 4.8 |
| NIDS | Suricata | 7.0 |
| Shipper | Filebeat | 8.14.3 |
| Reglas SIEM | ElastAlert2 | 2.19.0 |
| Métricas | Prometheus | 2.54 |
| Sondas activas | Blackbox Exporter | 0.25 |
| Notificación infra | Alertmanager | 0.27 |
| Dashboards infra | Grafana | 11 |
| Repositorio y CI/CD | GitLab CE + Runner | 17.6 |

## Capas de la Arquitectura

### Capa 1: Infraestructura (Terraform)

Terraform provisiona **4 VMs Ubuntu 22.04** en Proxmox VE mediante cloud-init:

- Usuarios `ansible` y `arodper` con `sudo NOPASSWD`.
- Claves SSH inyectadas vía cloud-init.
- IP estática en la VLAN 30 (`10.10.30.0/24`).
- El inventario Ansible (`hosts.ini`) se genera como output de Terraform.

`gitlab-core` (en VLAN 10) ya existía a la entrada del proyecto; se referencia en el inventario como host externo no gestionado por Terraform.

**Decisión:** Proxmox sobre soluciones cloud para mantener la soberanía de datos y reflejar un entorno on-premise realista de PYME / centro educativo.

### Capa 2: Configuración (Ansible)

13 playbooks ordenados por dependencias despliegan todo el stack. Los roles son reutilizables e idempotentes:

| # | Playbook | Despliega |
| :---: | :--- | :--- |
| 01 | `01-configuracion-base.yml` | Hardening mínimo + Docker en todos los nodos |
| 02 | `02-desplegar-step-ca.yml` | CA interna en `edge-core` |
| 03 | `03-desplegar-traefik-interno.yml` | Reverse proxy TLS (toma certs de step-ca) |
| 04 | `04-desplegar-wazuh.yml` | Wazuh Manager + VD + API REST |
| 05 | `05-desplegar-elk.yml` | Elasticsearch + Kibana + Logstash + dashboards + Reconciler |
| 06 | `06-desplegar-filebeat-wazuh.yml` | Filebeat empujando alertas Wazuh a Logstash |
| 07 | `07-desplegar-suricata.yml` | NIDS en `ids-core` |
| 08 | `08-desplegar-filebeat-suricata.yml` | Filebeat empujando `eve.json` a Logstash |
| 09 | `09-desplegar-wazuh-agent.yml` | Agentes Wazuh en todos los nodos |
| 10 | `10-desplegar-monitoring.yml` | Prometheus + Grafana + Alertmanager en `obs-core` |
| 11 | `11-desplegar-node-exporter.yml` | Node Exporter en todos los nodos |
| 12 | `12-desplegar-elastalert.yml` | Reglas ElastAlert2 a Telegram |
| 13 | `13-verificar-despliegue.yml` | Health checks automatizados |

| Subsistema | Roles implicados | Containerizado |
|:---|:---|:---|
| Wazuh Manager | `stack_wazuh` | Sí (Docker) |
| ELK Stack | `stack_elk` | Sí (Docker Compose) |
| Suricata IDS | `stack_suricata` | Sí (Docker) |
| Reconciler CVE | `stack_wazuh_reconciler` | No (systemd timer + Python) |
| ElastAlert2 | `stack_elastalert` | Sí (Docker) |
| Prometheus/Grafana/Alertmanager/Blackbox | `stack_monitoring` | Sí (Docker Compose) |
| Step-CA | `stack_step_ca` | Sí (Docker) |
| Traefik | `stack_traefik_internal` | Sí (Docker) |

### Capa 3: Detección (HIDS + NIDS)

| Motor | Tipo | Qué detecta |
|:---|:---|:---|
| **Wazuh** | HIDS | Integridad de ficheros (FIM), rootkits, vulnerabilidades (VD), autenticación, logs del sistema |
| **Suricata** | NIDS | Tráfico malicioso, exploits de red, C2, malware, escaneos de puertos |

Ambos motores alimentan el mismo pipeline de ingesta (Logstash → Elasticsearch).

**Limitación reconocida:** los Intel NUC tienen una única NIC física, por lo que no se puede configurar un puerto SPAN/mirror dedicado a nivel de switch. Suricata opera de forma **virtualizada sobre la VM `ids-core`**, analizando exclusivamente el tráfico que atraviesa su propia interfaz virtual dentro de la VLAN 30. El pipeline NIDS completo está operativo (captura → análisis → indexación → alertado), pero su cobertura de red es local al nodo, no del segmento completo. El despliegue de una sonda física dedicada queda recogido como línea de trabajo futuro.

### Capa 4: Almacenamiento y Correlación (ELK)

```
Agentes/Filebeat → Logstash (parsing + enriquecimiento) → Elasticsearch (almacenamiento + indexación)
                                                          ↓
                                                        Kibana (dashboards)
                                                        ElastAlert2 (alertas Telegram)
                                                        Transform (inventario CVE)
```

**Decisión:** Logstash como punto intermedio (en lugar de Filebeat directo a ES) para normalizar campos entre Wazuh y Suricata, actuar como buffer ante picos y aplicar filtros y enriquecimiento antes de indexar.

### Capa 5: Gestión de Vulnerabilidades (Dual-Plane)

El sistema de CVEs usa dos planos y **tres piezas** que cooperan:

- **History plane (`wazuh-alerts-*`):** Todos los eventos del VD como logs inmutables.
- **State plane (`wazuh-vulnerabilities-inventory`):** Vista materializada con la última tripla `(agente, CVE, paquete)`.

Las tres piezas que lo construyen:

1. **Elasticsearch Transform.** Agrupa por `(agent.id, cve, package.name)` y conserva el último evento por grupo (`top_metrics` con `sort: @timestamp desc`). Sync continuo cada 60 s.
2. **Ingest Pipeline (Painless).** Promueve los campos anidados de `latest_event.*` a la raíz canónica (`agent.name`, `rule.id`, `data.vulnerability.severity`), para que los controles globales de Kibana funcionen al unísono sobre todos los paneles.
3. **Wazuh-Vuln-Reconciler.** Servicio systemd con timer que cruza el inventario con la API `syscollector` de Wazuh y purga del índice los CVEs cuyos paquetes ya no están instalados (escenario `apt purge`, que Wazuh no notifica con rule `23502`).

**Decisión:** El Transform es superior a un script batch porque se sincroniza continuamente y la deduplicación la hace el motor. El Reconciler cierra el gap del Transform cuando un paquete desaparece sin que el VD emita evento de resolución.

### Capa 6: Alertado (ElastAlert2 + Alertmanager)

| Origen | Motor | Reglas iniciales |
|:---|:---|:---|
| Eventos de seguridad | ElastAlert2 (8 reglas) | `wazuh_critica`, `wazuh_brute_force`, `wazuh_fim`, `wazuh_vuln_nuevo`, `wazuh_vuln_resuelto`, `wazuh_agente_desconectado`, `suricata_critica`, `suricata_anomalia` |
| Métricas de infraestructura | Alertmanager | Nodo caído, disco > 85 %, CPU sostenida, certificado próximo a caducar, target down |

Ambos motores entregan a Telegram a través de **un único bot** con dos prefijos: `[INFRA]` (Alertmanager) y `[SIEM]` (ElastAlert2). Cada alerta `[SIEM]` incluye enlace directo a Kibana Discover.

### Capa 7: Active Response

Wazuh responde automáticamente ante amenazas mediante `firewall-drop` (iptables):

| Trigger | Regla Wazuh | Acción | Timeout |
|:---|:---|:---|:---|
| Brute force SSH | 5710 (`authentication_failed`, agrupada) | Bloqueo IP origen | 30 min |

La respuesta activa es configurable vía `active_response_enabled` en `group_vars/wazuh.yml`. La red interna (`10.10.0.0/16`) está en whitelist para evitar auto-bloqueo entre nodos.

### Capa 8: Observabilidad

Prometheus + Grafana + Alertmanager + Blackbox Exporter en `obs-core` monitorizan la salud de toda la infraestructura:

- **Node Exporter** en cada nodo (5 VMs): CPU, RAM, disco, red.
- **Blackbox Exporter**: sondas HTTP(S) y TCP contra Elasticsearch, Kibana, Grafana, API step-ca, Wazuh manager 1514/55000.
- **Dashboards Grafana** provisionados como código desde Ansible.
- **Alertmanager** notifica con prefijo `[INFRA]` a Telegram, con soporte nativo `firing` / `resolved`.

Separado del plano SIEM: si `sec-core` falla, `obs-core` sigue avisando.

## Flujo de Red

```
Internet / LAN
       │
       ▼
 [edge-core :443] ─── Traefik (TLS) ─── Step-CA (PKI)
       │
       ├── kibana.lab.wiswok.net      → sec-core:5601
       ├── grafana.lab.wiswok.net     → obs-core:3000
       ├── prometheus.lab.wiswok.net  → obs-core:9090
       ├── alertmanager.lab.wiswok.net→ obs-core:9093
       ├── gitlab.lab.wiswok.net      → gitlab-core:80 (HTTP→HTTPS)
       └── ca.lab.wiswok.net          → edge-core:9000 (step-ca)
```

Todos los paneles internos son accesibles únicamente a través de Traefik con certificados TLS emitidos por step-ca.

## Segmentación de Red

| Segmento | VLAN | Hosts | Propósito |
|:---|:---|:---|:---|
| `10.10.10.0/24` | 10 | `gitlab-core` (más el host del operador / runner) | Gestión y DevSecOps |
| `10.10.30.0/24` | 30 | `edge-core`, `sec-core`, `obs-core`, `ids-core` | Operativa SIEM |

El tráfico inter-VLAN está bloqueado por defecto. Reglas granulares permiten exclusivamente el acceso necesario:

- VLAN 10 → VLAN 30 puertos 80/443 (Traefik) para acceder a los paneles.
- VLAN 10 → VLAN 30 puerto 22 SSH restringido al runner / estación del operador.
- Acceso a los puertos internos de los componentes (ES 9200, Kibana 5601, etc.) bloqueado desde fuera.

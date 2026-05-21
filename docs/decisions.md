# Architecture Decision Records (ADR)

## ADR-001: Docker para todos los servicios, incluyendo Suricata

**Estado:** Aceptado
**Contexto:** Necesitamos desplegar múltiples servicios (Wazuh, ELK, Grafana, Step-CA, Traefik, ElastAlert2, Suricata) de forma reproducible.
**Decisión:** Todos los servicios, incluyendo Suricata, se despliegan como contenedores Docker.
**Razón:**
- Docker permite un despliegue limpio e idempotente vía Ansible (`community.docker`).
- Suricata, aunque necesite acceso a la NIC, se ejecuta dentro de la VM `ids-core` con la capacidad `NET_ADMIN` y `--net=host` sobre la interfaz virtual de la propia VM.
- Evita gestionar dependencias de paquetes nativos (PPA), garantizando que todos los servicios compartan el mismo modelo de gestión basado en contenedores.

**Consecuencias:** Suricata usa la red del host de la VM, anulando parcialmente el aislamiento de red de Docker para este contenedor, pero facilitando enormemente su ciclo de vida. Su cobertura de red se limita al tráfico que atraviesa la interfaz virtual de `ids-core` (los NUC tienen una sola NIC física, sin puerto mirror físico).

---

## ADR-002: Logstash como punto intermedio de ingesta

**Estado:** Aceptado
**Contexto:** Wazuh y Suricata generan eventos en formatos distintos que deben indexarse en Elasticsearch.
**Decisión:** Usar Logstash entre los Filebeats y Elasticsearch, en lugar de enviar directo a ES.
**Razón:**
- Logstash permite normalizar campos entre fuentes heterogéneas en un único punto.
- Actúa como buffer ante picos de ingesta (cola interna persistente).
- Permite filtrar, enriquecer y transformar antes de indexar, reduciendo carga en ES.

**Alternativa descartada:** Filebeat → Elasticsearch directo. Más simple pero sin capacidad de transformación ni buffering.

---

## ADR-003: Inventario CVE con Elasticsearch Transform (entity-centric)

**Estado:** Aceptado
**Contexto:** Wazuh VD emite eventos individuales por cada CVE detectado y los re-emite en cada scan. Necesitamos una vista actualizada del estado real de vulnerabilidades por agente.
**Decisión:** Elasticsearch Transform + Ingest Pipeline + Reconciler systemd. Tres piezas que cooperan.
**Razón:**
- El Transform agrupa por `(agent.id, cve, package.name)` y conserva el último evento por grupo (sync 60 s). La deduplicación la hace ES nativamente.
- El Ingest Pipeline (Painless) promueve los campos anidados de `latest_event.*` a la raíz canónica, lo que permite que los controles globales de Kibana (filtro por agente, severidad, etc.) afecten al unísono a todos los paneles del dashboard.
- El Reconciler cubre el gap del Transform: cuando un paquete vulnerable se elimina vía `apt purge`, Wazuh no emite alerta de "CVE resuelta" (rule `23502`); el Reconciler consulta la API `syscollector` y purga del índice los registros huérfanos.

**Alternativa descartada:** Script Python batch que reescribe un índice. Más frágil, más lento, y duplica esfuerzo con lo que ya hace ES.

---

## ADR-004: Reconciler como servicio systemd (no Docker)

**Estado:** Aceptado
**Contexto:** El reconciler cruza la API de Wazuh con el inventario en Elasticsearch para eliminar CVEs huérfanos.
**Decisión:** Script Python con systemd timer, no contenedor Docker.
**Razón:**
- Necesita acceso a `localhost:55000` (API Wazuh dentro de Docker) y `localhost:9200` (ES dentro de Docker). Desde un contenedor requeriría `--net=host`.
- Un timer systemd es más simple de monitorizar (`systemctl`, `journalctl`) que un cron dentro de un contenedor.
- El script es autocontenido (solo stdlib Python), no requiere `requirements.txt` ni imagen custom.

**Consecuencias:** Las credenciales se pasan vía EnvironmentFile (`/etc/default/wazuh-reconciler`) con permisos `0600`.

---

## ADR-005: Step-CA como PKI interna con ACME

**Estado:** Aceptado
**Contexto:** Todos los dashboards (Kibana, Grafana, Prometheus, GitLab, etc.) deben ser accesibles por HTTPS dentro del laboratorio.
**Decisión:** Smallstep step-ca como CA interna con provisioner ACME, consumida por Traefik.
**Razón:**
- step-ca expone un endpoint ACME compatible: Traefik solicita y renueva certificados automáticamente vía TLS-ALPN-01.
- El raíz se distribuye al cliente del operador → candado verde sin advertencias en el navegador.
- Centraliza la gestión de PKI: un único punto para emitir, revocar y rotar.

**Alternativa descartada:** Let's Encrypt. No aplica en redes internas sin acceso público y sin dominio público propio para el laboratorio.

---

## ADR-006: ElastAlert2 para correlación y alertado a Telegram

**Estado:** Aceptado
**Contexto:** Necesitamos alertas en tiempo real sobre eventos de seguridad críticos, entregadas a un canal accesible desde el móvil.
**Decisión:** ElastAlert2 con **8 reglas** que consultan Elasticsearch y envían a Telegram.
**Razón:**
- ElastAlert2 es el sucesor mantenido de ElastAlert, diseñado específicamente para Elasticsearch.
- Las reglas son ficheros YAML versionables y desplegables con Ansible.
- Telegram es instantáneo, gratuito y accesible desde cualquier dispositivo.

Las 8 reglas iniciales: `wazuh_critica`, `wazuh_brute_force`, `wazuh_fim`, `wazuh_vuln_nuevo`, `wazuh_vuln_resuelto`, `wazuh_agente_desconectado`, `suricata_critica`, `suricata_anomalia`.

**Alternativa descartada:** Watcher de Elasticsearch (X-Pack). Requiere licencia Platinum y es menos flexible para customización.

---

## ADR-007: Prometheus + Grafana para observabilidad (separado de ELK)

**Estado:** Aceptado
**Contexto:** Necesitamos monitorizar la salud de la infraestructura (CPU, RAM, disco, contenedores, sondas activas).
**Decisión:** Stack separado Prometheus + Grafana + Alertmanager + Blackbox Exporter en `obs-core`, independiente de ELK.
**Razón:**
- Prometheus está optimizado para métricas numéricas con series temporales. Elasticsearch no lo está.
- Separar en nodos distintos evita que un problema de recursos en `sec-core` (ELK) deje sin visibilidad operativa.
- Node Exporter es el estándar de facto para métricas del sistema Linux.

**Consecuencias:** Ver ADR-011 para la estrategia de entrega a Telegram (canal único, prefijos distintos).

---

## ADR-008: Ansible como único orquestador de configuración

**Estado:** Aceptado
**Contexto:** La configuración de 5 nodos con ~15 servicios necesita una herramienta de gestión.
**Decisión:** Ansible como único orquestador, sin agente, operando sobre SSH.
**Razón:**
- Sin agente: no requiere software adicional en los nodos gestionados.
- Idempotente: re-ejecutar un playbook no causa efectos secundarios.
- YAML declarativo: fácil de leer, versionar y auditar.
- Integración nativa con Docker (`community.docker`), systemd y APIs REST.

**Alternativa descartada:** Puppet/Chef. Requieren agente en cada nodo y servidor central, añadiendo complejidad innecesaria.

---

## ADR-009: Active Response con firewall-drop (iptables)

**Estado:** Aceptado
**Contexto:** La monitorización pasiva detecta ataques pero no los detiene. Necesitamos respuesta automatizada.
**Decisión:** Active Response de Wazuh con `firewall-drop` ante brute force SSH.
**Razón:**
- `firewall-drop` usa iptables, disponible en cualquier Linux sin dependencias adicionales.
- El timeout configurable (30 min) evita bloqueos permanentes.
- La whitelist de la red interna (`10.10.0.0/16`) previene auto-bloqueo entre nodos.
- Trigger inicial: regla **5710** (`authentication_failed`) agrupada por IP origen.

**Alternativa considerada:** CrowdSec. Más sofisticado pero añade un servicio adicional y complejidad operativa.

---

## ADR-010: Bootstrap inicial fuera del runner de GitLab CI

**Estado:** Aceptado
**Contexto:** Durante la reconstrucción end-to-end (P-05) se identificó una **dependencia cíclica invisible** en operación normal:

```
Runner → HTTPS hacia gitlab.lab.wiswok.net → cert TLS firmado por step-ca → trust store del runner
```

Al destruir `edge-core`, step-ca genera una raíz nueva con fingerprint distinto. Los certificados que Traefik solicita vía ACME pasan a estar firmados por esa nueva raíz, mientras que el trust store del runner conserva la anterior. El runner deja de aceptar jobs y `deploy:full` no puede arrancar.

**Decisión:** Convención operativa — el primer despliegue del laboratorio se ejecuta **directamente desde la máquina del operador** con `ansible-playbook`, sin pasar por el runner. Tras alcanzar estado estable, las modificaciones posteriores fluyen ya por GitLab CI con el flujo GitOps habitual.

**Razón:**
- El bootstrap es un evento singular (el momento en que la PKI nace) que no puede depender de los propios componentes que está creando.
- La alternativa estructural (persistir la raíz fuera del ciclo de vida de `edge-core`) requiere infraestructura externa al laboratorio (gestor de secretos con backups) y queda recogida como línea de trabajo futuro.

**Consecuencias:** El manual de instalación documenta explícitamente la convención. El runner se utiliza solo a partir del segundo despliegue.

---

## ADR-011: Canal único de Telegram con doble prefijo `[INFRA]` / `[SIEM]`

**Estado:** Aceptado
**Contexto:** Dos motores de alertado conviven en la plataforma: ElastAlert2 (seguridad) y Alertmanager (infraestructura). Cada uno tiene su lógica, ventanas y deduplicación.
**Decisión:** Entregar ambas a **un único bot de Telegram** distinguiendo el origen mediante prefijo en el cuerpo del mensaje: `[INFRA] …` para Alertmanager, `[SIEM] …` para ElastAlert2.
**Razón:**
- Un único bot y grupo simplifica la configuración: un solo token, una sola plantilla base.
- El operador filtra mentalmente por prefijo y el contexto del mensaje lo deja inequívoco.
- Dos bots / dos grupos separados duplican config y se desincronizan con facilidad (rotación de tokens, permisos, etc.).
- Los avisos del runner CI/CD (resultado de pipelines) también van al mismo canal.

**Alternativa descartada:** Dos bots con dos grupos separados. Limpieza visual marginal a cambio de doble mantenimiento.

---

## ADR-012: Alertas clasificadas en tres categorías por naturaleza temporal

**Estado:** Aceptado
**Contexto:** En la configuración inicial todas las alertas de Wazuh se trataban como eventos puntuales y se enviaban al mismo canal sin distinguir su naturaleza. Esto producía dos clases de ruido:
- **Vulnerabilidades persistentes** reemitidas en cada ciclo del scanner.
- **Eventos FIM benignos** sobre rutas que cambian con cada actualización de paquetes.

Resultado: *alert fatigue*. Las notificaciones realmente importantes quedaban diluidas.

**Decisión:** Clasificar cada alerta por **naturaleza temporal** y aplicar la estrategia adecuada:

| Categoría | Ejemplos | Estrategia |
|---|---|---|
| **Estado continuo** | CPU alta, servicio caído, certificado próximo a caducar | `firing` / `resolved` (Prometheus) |
| **Hallazgo persistente** | CVE en paquete, *compliance check* | Notificación al aparecer y al desaparecer (`new_term` + `flatline`) |
| **Evento puntual** | Brute force, sudo fallido, FIM crítico, Suricata | Alerta única deduplicada por clave (`query_key` + `realert`) |

Acompañado de:
- Exclusión explícita de rutas FIM benignas (`/boot`, `/var/lib/apt`, `/var/cache`, `/var/log`, `/tmp`) en `agent.conf`.
- Ampliación del intervalo del módulo `vulnerability-detector` a 6-12 h (la respuesta a un CVE ocurre en días, no en minutos).
- Separación del scanner de vulnerabilidades del flujo de alertas críticas: la regla `wazuh_critica` deja de capturar `rule.groups: vulnerability-detector`.

**Razón:** El valor de un SIEM se mide por la fracción de alertas que conducen a una acción. Tratar las alertas como problema de diseño de producto (estado vs. evento, ciclo de vida apertura/cierre, deduplicación por entidad) reduce el ruido sin perder señal real.

**Resultado:** reducción aproximada del 99,5 % del volumen diario de notificaciones (de ~4 700 a < 25), conservando la cobertura funcional.

**Alternativa descartada:** Introducir un gestor de casos externo (TheHive, Shuffle). Excede el alcance del proyecto; queda como línea de trabajo futuro.

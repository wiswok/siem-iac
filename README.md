# 🚀 Diseño e implementación de una plataforma SIEMaaS automatizada con Terraform, Ansible y CI/CD 

[![Ansible](https://img.shields.io/badge/IaC-Ansible-red?style=for-the-badge&logo=ansible)](https://www.ansible.com/)
[![Docker](https://img.shields.io/badge/Container-Docker-2496ED?style=for-the-badge&logo=docker)](https://www.docker.com/)
[![Wazuh](https://img.shields.io/badge/SIEM-Wazuh-blue?style=for-the-badge&logo=wazuh)](https://wazuh.com/)
[![ELK Stack](https://img.shields.io/badge/Logging-Elasticsearch-005571?style=for-the-badge&logo=elastic-stack)](https://www.elastic.co/)
[![Suricata](https://img.shields.io/badge/NIDS-Suricata-E4002B?style=for-the-badge)](https://suricata.io/)
[![Certificates](https://img.shields.io/badge/PKI-Step--CA-purple?style=for-the-badge)](https://smallstep.com/)

Infraestructura **SIEM (Security Information and Event Management)** distribuida, totalmente declarativa con **Ansible** y **Docker**, diseñada para monitorización, detección de intrusiones, gestión de vulnerabilidades y respuesta ante incidentes en tiempo real.

---

## 🗺️ Topología de la Red & Nodos

La infraestructura está segmentada en roles específicos para garantizar separación de responsabilidades y escalabilidad:

| Host | IP | Rol Principal | Tecnologías |
| :--- | :--- | :--- | :--- |
| **`sec-core`** | `10.10.30.10` | **Security Engine** | Wazuh Manager, ELK Stack, ElastAlert, Reconciler |
| **`ids-core`** | `10.10.30.30` | **Intrusion Detection** | Suricata IDS, Filebeat, Wazuh Agent |
| **`obs-core`** | `10.10.30.20` | **Observability** | Prometheus, Grafana, Alertmanager, Wazuh Agent |
| **`edge-core`** | `10.10.30.5` | **Network Edge** | Step-CA, Traefik interno, Wazuh Agent |
| **`gitlab-core`** | `10.10.10.40` | **DevSecOps** | GitLab, Wazuh Agent |

> La red `10.10.30.0/24` agrupa los servicios de seguridad y observabilidad; `gitlab-core` vive en un segmento distinto (`10.10.10.0/24`) para simular un entorno multi-VLAN.
>
> Terraform provisiona las **4 VMs operativas** de la VLAN 30. `gitlab-core` preexiste a este proyecto y se referencia en el inventario Ansible como host externo para desplegar únicamente el agente Wazuh. En total: **4 VMs creadas por Terraform + 1 preexistente** = 5 VMs gestionadas por Ansible.

---

## 🛠️ Capacidades en Una Línea

- **HIDS + NIDS + gestión de CVEs** integrados sobre la misma instancia ELK *single-node*.
- **Inventario de vulnerabilidades entity-centric** (Transform + Ingest Pipeline + Reconciler) sincronizado con el estado real de paquetes.
- **Alertado dual a Telegram** con prefijos `[INFRA]` (Alertmanager) y `[SIEM]` (ElastAlert2).
- **PKI interna** con Step-CA + reverse proxy TLS Traefik para todos los paneles internos.
- **Active Response** automatizada (bloqueo IP vía iptables ante brute force SSH).

> El desglose por capas, motores y reglas concretas vive en [docs/architecture.md](docs/architecture.md) y [docs/security-model.md](docs/security-model.md).

---

## 🗂️ Estructura del Repositorio

```
siem/
├── terraform/                         # Provisión de VMs en Proxmox (cloud-init)
│   ├── main.tf                        # 4 VMs + inventario Ansible autogenerado
│   ├── provider.tf                    # Proxmox bpg/proxmox v0.97.1
│   ├── variables.tf
│   └── credentials.auto.tfvars.example
├── ansible/
│   ├── ansible.cfg                    # Config (vault_password_file, roles_path…)
│   ├── inventory/
│   │   ├── hosts.ini                  # Generado por Terraform
│   │   └── group_vars/                # Vars por grupo (vault incluido)
│   ├── playbooks/                     # 13 playbooks numerados (01–12 despliegue + 13 verificación)
│   └── roles/                         # 15 roles reutilizables
├── docs/                              # Documentación de arquitectura, seguridad y operativas
└── README.md
```

---

## 📦 Despliegue y Operación (CI/CD GitOps)

El ciclo de vida de la infraestructura sigue un modelo **GitOps**: Terraform provisiona la infraestructura, Ansible la configura, y el pipeline GitLab CI dispara `deploy:full` en cada commit a `main`. El artefacto que conecta ambas etapas es `hosts.ini`, generado automáticamente tras `terraform apply`.

### ✅ Requisitos Previos

| Requisito | Detalle |
| :--- | :--- |
| **Proxmox VE** | Cluster con ≥ 3 nodos (`pve1`, `pve2`, `pve3`) y bridge `vmbr0` con VLAN 30. |
| **API token Proxmox** | Usuario `terraform@pve` con rol `TerraformRole` (creación detallada en el [Runbook](docs/runbook.md#bootstrap-inicial-del-laboratorio)). |
| **Claves SSH locales** | `~/.ssh/id_ed25519` (usuario `ansible`) y `~/.ssh/id_ed25519_ops` (usuario `arodper`). |
| **gitlab-core** | VM externa preexistente en `10.10.10.40` (no la crea Terraform; solo Ansible despliega el agente Wazuh). |
| **Terraform y Ansible** | Terraform ≥ **1.9**, Ansible ≥ **2.17** con colecciones `community.docker`, `community.general`, `ansible.posix`. |
| **DNS interno** | Resolución de `*.lab.wiswok.net` apuntando a `edge-core` (Traefik). |
| **Vault password** | Fichero `.vault_pass` en la raíz del repo (excluido por `.gitignore`). |
| **Bot de Telegram** | Token + chat ID cifrados en `group_vars/all.yml` vía `ansible-vault`. Bot único con prefijos `[INFRA]` / `[SIEM]`. |

### 🚀 Despliegue desde Cero (Quick Start)

```bash
# 1. Clonar e instalar dependencias
git clone <repo-url> siem && cd siem
ansible-galaxy collection install community.docker community.general ansible.posix
echo "TU_VAULT_PASSWORD" > .vault_pass && chmod 600 .vault_pass

# 2. Provisión con Terraform (crea 4 VMs y genera hosts.ini)
cd terraform
cp credentials.auto.tfvars.example credentials.auto.tfvars
$EDITOR credentials.auto.tfvars      # 4 variables: api_url, api_user, api_token, password
terraform init && terraform apply

# 3. Configuración con Ansible (13 playbooks en orden)
cd ../ansible
ansible all -m ping                  # verificar conectividad
for pb in playbooks/*.yml; do ansible-playbook "$pb" || break; done
```

> El **primer despliegue se ejecuta desde la máquina del operador**, no desde el runner de CI, por una dependencia cíclica entre la PKI interna y el runner. Detalle y procedimiento completo en el [Runbook → Bootstrap inicial](docs/runbook.md#bootstrap-inicial-del-laboratorio).

### 📋 Playbooks (resumen)

13 playbooks numerados (`01-configuracion-base.yml` … `12-desplegar-elastalert.yml` + `13-verificar-despliegue.yml`) cuya ejecución secuencial respeta todas las dependencias. La tabla completa con qué despliega cada uno vive en [docs/architecture.md → Capa de configuración](docs/architecture.md#capa-2-configuración-ansible).

### 🧪 Validación Post-Despliegue

```bash
cd ansible
ansible-playbook playbooks/13-verificar-despliegue.yml
```

Comprueba Elasticsearch, Kibana, Wazuh API, Transform CVE, Reconciler, Suricata, Prometheus, Grafana, Step-CA, Traefik y agentes Wazuh. Desglose en el [Runbook → Verificación Post-Despliegue](docs/runbook.md#verificación-post-despliegue).

### 🔁 Operación GitOps (CI/CD)

Tras el bootstrap inicial, la operativa diaria sigue el patrón **GitOps**: cualquier cambio (cadencia del reconciler, reglas de ElastAlert, rotación de credenciales) entra como *commit* en `main` y el pipeline `deploy:full` lo aplica automáticamente.

**Variables CI/CD requeridas en GitLab:**

| Variable | Descripción |
| :--- | :--- |
| `SSH_PRIVATE_KEY` | Clave privada SSH del usuario `ansible`. |
| `VAULT_PASS` | Contraseña del vault de Ansible. |

Detalle del pipeline, jobs `deploy:01-base` … `deploy:13-verificar` y patrón de operación manual: [docs/runbook.md → Operaciones habituales](docs/runbook.md).

### 🚨 Troubleshooting

Problemas habituales (claves SSH, DNS, vault, Elasticsearch RED, Transform parado, contenedores fallando, IDS/IPS bloqueando al runner, etc.) en [docs/runbook.md → Troubleshooting](docs/runbook.md#troubleshooting).


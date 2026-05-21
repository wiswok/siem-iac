# Runbook de Operaciones

## Bootstrap inicial del laboratorio

> **Importante.** El primer despliegue del laboratorio se ejecuta **desde la máquina del operador**, no desde el runner de GitLab CI. Razón documentada en [ADR-010](decisions.md#adr-010-bootstrap-inicial-fuera-del-runner-de-gitlab-ci): existe una dependencia cíclica entre la PKI interna (step-ca) y el trust store del runner que impide arrancar `deploy:full` sobre infraestructura recién creada.

### 1. Generación de claves SSH

Terraform y Ansible necesitan dos claves SSH:

```bash
# Clave del usuario de automatización (Ansible)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "ansible@lab.wiswok.net"

# Clave del operador para administración manual
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ops -C "arodper@lab.wiswok.net"
```

Las dos rutas se referencian con `pathexpand("~/.ssh/...")` en `terraform/main.tf` y con `~/.ssh/...` en `ansible/inventory/hosts.ini`, así que funcionan tanto en la estación del operador como en el runner sin editar nada.

### 2. Instalación de herramientas (Ubuntu/Debian)

```bash
sudo apt-get update && sudo apt-get install -y \
    gnupg software-properties-common curl git python3-pip

# Terraform desde el repositorio oficial de HashiCorp
curl -fsSL https://apt.releases.hashicorp.com/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Ansible (PPA oficial o paquete)
sudo apt-get install -y ansible

# Colecciones requeridas
ansible-galaxy collection install community.docker community.general ansible.posix
```

### 3. Configuración de Proxmox (usuario y token API)

En la shell del nodo Proxmox principal:

```bash
# Rol con permisos mínimos necesarios para Terraform
pveum role add TerraformRole -privs "\
    Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,\
    Sys.Audit,Sys.Modify,Sys.PowerMgmt,\
    VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.Cloudinit,VM.Config.CPU,\
    VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
    VM.Console,VM.Migrate,VM.PowerMgmt,\
    VM.GuestAgent.Audit,VM.GuestAgent.Unrestricted,\
    SDN.Use"

# Usuario de automatización + asignación del rol
pveum user add terraform@pve --comment "Terraform automation user"
pveum aclmod / -user terraform@pve -role TerraformRole

# Token API (guarda el secreto generado)
pveum user token add terraform@pve terraform-token --privsep 0
```

Las 4 variables a rellenar en `terraform/credentials.auto.tfvars`:

```hcl
proxmox_api_url   = "https://<proxmox-host>:8006/api2/json"
proxmox_api_user  = "terraform@pve!terraform-token"
proxmox_api_token = "<secret-del-token>"
proxmox_password  = "<password-SSH-root-de-proxmox>"
```

### 4. Vault password

```bash
echo "TU_VAULT_PASSWORD" > .vault_pass
chmod 600 .vault_pass
```

Si `telegram_bot_token` / `telegram_chat_id` no son los del autor:

```bash
ansible-vault edit ansible/inventory/group_vars/all.yml
```

### 5. Primer despliegue

```bash
# Provisión Terraform (4 VMs + hosts.ini generado)
cd terraform
terraform init
terraform apply

# Configuración Ansible (13 playbooks)
cd ../ansible
ansible all -m ping
for pb in playbooks/*.yml; do ansible-playbook "$pb" || break; done
```

A partir de aquí, las modificaciones posteriores ya pueden fluir vía GitLab CI con `deploy:full` (el runner ya confía en la PKI que se acaba de generar, una vez se le distribuya el certificado raíz).

## Reconstrucción end-to-end del laboratorio

Procedimiento que valida la prueba P-05 de la memoria. Tiempo total aproximado: **~17 min**.

```bash
# 1. (Opcional) backup de seguridad con vzdump en Proxmox antes de destruir
# vzdump 100 101 102 103 --storage local --compress zstd

# 2. Destruir las 4 VMs operativas (gitlab-core no se toca)
cd terraform
terraform destroy

# 3. Recrear las VMs desde cero
terraform apply

# 4. Esperar a que cloud-init termine en las 4 VMs
ansible all -m raw -a "cloud-init status --wait" -i inventory/hosts.ini

# 5. Reaplicar los 13 playbooks (bootstrap manual)
cd ../ansible
for pb in playbooks/*.yml; do ansible-playbook "$pb" || break; done
```

Tras P-05 los roles incluyen reintentos y comprobaciones funcionales (no solo "puerto abierto") que absorben los arranques en frío. La salida esperada es `PLAY RECAP` sin un solo `failed` en ninguno de los hosts.

## Procedimientos de operación habitual

### Investigar una alerta de Telegram

1. **Identificar el tipo de alerta.** El mensaje incluye prefijo (`[INFRA]` o `[SIEM]`), título de la regla, timestamp y agente/nodo afectado.

2. **Acceder al dashboard correspondiente:**
   - `[SIEM]` Wazuh → `https://kibana.lab.wiswok.net` → Dashboard "SIEM - Wazuh HIDS"
   - `[SIEM]` Suricata → Dashboard "SIEM - Suricata IDS"
   - `[SIEM]` CVE → Dashboard "SIEM - Vulnerabilidades"
   - `[INFRA]` → `https://grafana.lab.wiswok.net`

3. **Filtrar por agente y rango temporal** en Kibana.
4. **Expandir el evento** en la saved search para ver el documento JSON completo.
5. **Documentar y actuar** según el tipo de incidente.

### Añadir un nuevo agente Wazuh

```bash
# 1. Asegurar que el nuevo host tiene acceso SSH y está en hosts.ini
echo "nuevo-host ansible_host=10.10.30.XX" >> ansible/inventory/hosts.ini

# 2. Añadir al grupo wazuh_agents en hosts.ini

# 3. Ejecutar el playbook de agentes
cd ansible
ansible-playbook playbooks/09-desplegar-wazuh-agent.yml --limit nuevo-host
```

### Rotar credenciales del vault

```bash
# 1. Editar secretos
ansible-vault edit inventory/group_vars/all.yml
ansible-vault edit inventory/group_vars/wazuh.yml

# 2. Si se cambia la contraseña del vault:
ansible-vault rekey inventory/group_vars/all.yml
ansible-vault rekey inventory/group_vars/wazuh.yml
echo "NUEVA_PASSWORD" > .vault_pass
chmod 600 .vault_pass

# 3. Actualizar la variable VAULT_PASS en GitLab CI/CD Settings
```

### Rotar el token de Telegram

```bash
# 1. Crear nuevo bot en @BotFather y obtener token
# 2. Actualizar en el vault
ansible-vault edit inventory/group_vars/all.yml
# Cambiar telegram_bot_token y/o telegram_chat_id

# 3. Re-desplegar ElastAlert y Monitoring
ansible-playbook playbooks/12-desplegar-elastalert.yml
ansible-playbook playbooks/10-desplegar-monitoring.yml
```

### Añadir una regla de ElastAlert

1. Crear el template en `roles/stack_elastalert/templates/rules/nombre_regla.yml.j2`.
2. Seguir el patrón de las reglas existentes (ver `wazuh_brute_force.yml.j2`).
3. Re-desplegar:

```bash
ansible-playbook playbooks/12-desplegar-elastalert.yml
```

### Forzar refresco de dashboards Kibana

```bash
ansible-playbook playbooks/05-desplegar-elk.yml --tags dashboards
```

### Forzar reconciliación inmediata de CVEs

```bash
ansible sec-core -m command -a "systemctl start wazuh-vuln-reconciler.service"
ansible sec-core -m command -a "journalctl -u wazuh-vuln-reconciler.service --no-pager -n 20"
```

### Actualizar reglas de Suricata

```bash
ansible ids-core -m command -a "docker exec suricata suricata-update"
ansible ids-core -m command -a "docker restart suricata"
```

## Troubleshooting

### Errores de despliegue (Ansible / DNS)

- **`ERROR! Attempting to decrypt but no vault secrets found`** — falta crear `.vault_pass` en la raíz con permisos `600`.
- **`ssh: Permission denied`** — clave o usuario mal configurados. Ajusta `ansible_user` o `ansible_ssh_private_key_file` en `inventory/hosts.ini`.
- **`kibana.lab.wiswok.net` no resuelve** — DNS interno no configurado. Añade entrada en `/etc/hosts` apuntando a `10.10.30.5`.
- **`Connection timed out` intermitente en `deploy:full`** — el motor IDS/IPS del UDM Pro puede estar bloqueando al runner por patrón "SSH OUTBOUND scan" (SID `2003068`). Aplicar *Signature Suppression* en la UDM Pro para la IP del runner. Detalle completo en *Cuestiones reseñables* de la memoria.

### Elasticsearch en estado RED

```bash
# Shards sin asignar
curl -s http://10.10.30.10:9200/_cat/shards?v | grep UNASSIGNED

# Forzar reasignación
curl -XPOST 'http://10.10.30.10:9200/_cluster/reroute?retry_failed=true'
```

### Transform de vulnerabilidades parado o Dashboards CVE vacíos

```bash
# Estado
curl -s http://10.10.30.10:9200/_transform/wazuh-vulnerabilities-inventory/_stats | python3 -m json.tool

# Reinicio
curl -XPOST http://10.10.30.10:9200/_transform/wazuh-vulnerabilities-inventory/_stop?force=true
curl -XPOST http://10.10.30.10:9200/_transform/wazuh-vulnerabilities-inventory/_start
```

### Reconciler borra siempre 0 docs

El agente no ha enviado un scan reciente de `syscollector`. Reiniciar el agente en el host afectado o reducir el `<interval>` en `agent.conf.j2`.

### Agente Wazuh en `never_connected`

```bash
ansible <host> -m command -a "netstat -tlnp | grep 1514"

ansible-playbook playbooks/09-desplegar-wazuh-agent.yml \
  --limit <host> \
  -e wazuh_agent_force_reenroll=true
```

### ElastAlert no envía alertas

```bash
ansible sec-core -m command -a "docker logs --tail 50 elastalert"
ansible-vault view inventory/group_vars/all.yml
```

> Si el contenedor `elastalert` queda en `Exited (1)` tras un `docker restart`, recrearlo con `docker compose up -d --force-recreate` (el handler del rol ya lo hace, pero el primer arranque manual a veces lo deja con el entrypoint default que muere por EOF).

### Contenedor Docker no arranca

```bash
ansible <host> -m command -a "docker ps -a"
ansible <host> -m command -a "docker logs <container_name>"
ansible <host> -m command -a "docker compose -f /opt/siem/<stack>/docker-compose.yml up -d --force-recreate"
```

### Disco lleno en sec-core

```bash
ansible sec-core -m command -a "df -h"
ansible sec-core -m command -a "du -sh /opt/siem/*"

# Purgar índices antiguos
curl -XDELETE 'http://10.10.30.10:9200/wazuh-alerts-4.x-2025.03.*'

# Purgar logs de Docker
ansible sec-core -m command -a "docker system prune -f"
```

## Verificación Post-Despliegue

```bash
cd ansible
ansible-playbook playbooks/13-verificar-despliegue.yml
```

Comprobaciones automáticas:

| Comprobación | Nodo | Qué valida |
| :--- | :--- | :--- |
| **Elasticsearch** | `sec-core` | Cluster health ≠ red, shards activos |
| **Kibana** | `sec-core` | `/api/status` con `overall.level: available` |
| **Wazuh API** | `sec-core` | Endpoint REST respondiendo (HTTP 401 esperado sin token) |
| **Transform CVE** | `sec-core` | Estado `started` y docs procesados |
| **Reconciler** | `sec-core` | Timer systemd activo |
| **Suricata** | `ids-core` | Contenedor activo + reglas presentes |
| **Prometheus** | `obs-core` | Health check `/-/healthy` |
| **Grafana** | `obs-core` | Health check `/api/health` |
| **Step-CA + Traefik** | `edge-core` | Contenedores Docker corriendo |
| **Agentes Wazuh** | todos | Servicio `wazuh-agent` activo |
| **Telegram** | manual | `ansible obs-core -m command -a "docker stop alertmanager"` → verificar alerta `[INFRA]` al móvil |

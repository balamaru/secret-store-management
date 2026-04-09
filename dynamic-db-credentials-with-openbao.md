# Dynamic PostgreSQL Credentials with OpenBao
## 1. Prequesites
- OpenBao Installed
- CNPG Installed

## 2. Create and Setup PG Cluster
- Deploy PostgreSQL cluster
```sh
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-vault-poc
  namespace: openbao
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16

  bootstrap:
    initdb:
      database: appdb
      owner: app_owner
      secret:
        name: postgres-app-owner-secret
  storage:
    size: 2Gi
    storageClass: local-path
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"
EOF
```
- Create secret for app_owner
```sh
kubectl create secret generic postgres-app-owner-secret --namespace openbao --from-literal=username=app_owner --from-literal=password=AppOwner2026!
# PG service 
# postgres-vault-poc-rw → read-write (primary) — Vault will use this one
# postgres-vault-poc-ro → read-only (replica)
# postgres-vault-poc-r  → round-robin
```
- Login to PostgreSQL as superuser
```sh
kubectl exec -it -n openbao postgres-vault-poc-1 -- psql -U postgres -d appdb

# Running this SQL command in psql: -- Create specific user for Vault (as admin who able to CREATE ROLE)
CREATE USER vault_admin WITH 
  SUPERUSER 
  CREATEROLE 
  CREATEDB 
  LOGIN 
  PASSWORD '4b977c578a52e4fa';

# Verify
\du vault_admin

# Use psql with separate parameter
kubectl exec -it -n openbao postgres-vault-poc-1 -- \
  psql \
  -h localhost \
  -U vault_admin \
  -d appdb \
  -c 'SELECT current_user, current_database();'
```

## 2. Configuration in Openbao
```sh
# Set ROOT_TOKEN
ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('openbao-init-ha.json')); print(d['root_token'])")
# Login to OpenBao
kubectl exec -n openbao openbao-0 -- bao login $ROOT_TOKEN
```
- Step 1: Enable database secrets engine
```sh
kubectl exec -n openbao openbao-0 -- bao secrets enable database
```
- Step 2: Configure connection to PostgreSQL
```sh
kubectl exec -n openbao openbao-0 -- \
  bao write database/config/postgres-vault-poc \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="readonly,readwrite,app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres-vault-poc-rw.openbao.svc.cluster.local:5432/appdb?sslmode=disable" \
  username="vault_admin" \
  password="VaultAdmin2026!"

# Verify connection
kubectl exec -n openbao openbao-0 -- bao read database/config/postgres-vault-poc
```
- Create role
```sh
# Creare readonly role (TTL 1 jam)
kubectl exec -n openbao openbao-0 -- \
  bao write database/roles/readonly \
  db_name="postgres-vault-poc" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Create readwrite role (TTL 1 jam)
kubectl exec -n openbao openbao-0 -- \
  bao write database/roles/readwrite \
  db_name="postgres-vault-poc" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Create app-role role (Short TTL 30 minutes for demo)
kubectl exec -n openbao openbao-0 -- \
  bao write database/roles/app-role \
  db_name="postgres-vault-poc" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="30m" \
  max_ttl="1h"

# Verify all roles
kubectl exec -n openbao openbao-0 -- bao list database/roles
kubectl exec -n openbao openbao-0 -- bao read database/roles/readonly
kubectl exec -n openbao openbao-0 -- bao read database/roles/readwrite

# Test generate credentials for readonly
kubectl exec -n openbao openbao-0 -- bao read database/creds/readonly

# Test generate credentials for readwrite
kubectl exec -n openbao openbao-0 -- bao read database/creds/readwrite

# Test generate credentials for app-role
kubectl exec -n openbao openbao-0 -- bao read database/creds/app-role

# Check all dynamic users in PostgreSQL
kubectl exec -n openbao postgres-vault-poc-1 -- psql -U postgres -d appdb -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%' ORDER BY valuntil;"

# Set password from generated credentials
READONLY_USER="v-root-readonly-T411g6UVMYbICSt2xT0i-1774490887"
READONLY_PASS="-Toc4hwfh-4qBBCSAngU"

# Test connection with PGPASSWORD
kubectl exec -n openbao postgres-vault-poc-1 -- \
  env PGPASSWORD="$READONLY_PASS" \
  psql -h localhost -U "$READONLY_USER" -d appdb \
  -c 'SELECT current_user, current_database();'

# Test readonly must be can't to INSERT
kubectl exec -n openbao postgres-vault-poc-1 -- \
  env PGPASSWORD="$READONLY_PASS" \
  psql -h localhost -U "$READONLY_USER" -d appdb \
  -c 'CREATE TABLE test_block (id serial); INSERT INTO test_block VALUES (1);'

# Revoke lease readonly
kubectl exec -n openbao openbao-0 -- \
  bao lease revoke database/creds/readonly/DFroIeUNdhCMWvdGiFJqKSiM

# Verify user already deleted from PostgreSQL
kubectl exec -n openbao postgres-vault-poc-1 -- \
  psql -U postgres -d appdb \
  -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%' ORDER BY valuntil;"

# Test connecton with revoked credentials — must be FAIL
kubectl exec -n openbao postgres-vault-poc-1 -- \
  env PGPASSWORD="$READONLY_PASS" \
  psql -h localhost -U "$READONLY_USER" -d appdb \
  -c 'SELECT current_user;' 2>&1
```
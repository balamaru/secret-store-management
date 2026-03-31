# Integrate OpenBao with OIDC Provider
In case we having a lot of teams or users, os we must to give minimum access (no root access/admin access) to separate roles in OpenBao.

## 1. Prequesites
- OpenBao Installed and configured
- Keycloak with admin access

## 2. Configure in Keycloak
- Create a new realm
    -Name: openbao
    - Enabled: ON

- Crate a new client for OpenBao
    - Client ID   : openbao
    - Client type : OpenID Connect
    - Client authentication : ON
    - Authorization : OFF
    - Authentication flow : Standard flow ✅, Direct access ✅
    - Root URL : http://your-openbao-url.com
    - Home URL : http://your-openbao-url.com
    - Valid redirect URIs:
        - http://your-openbao-url.com/ui/vault/auth/oidc/oidc/callback
        - http://localhost:8250/oidc/callback
    - Web origins : http://your-openbao-url.com

- Take client secrets, Clients → openbao → Credentials tab (save this secret)
- Add group claim to the token, Clients → openbao → Client scopes tab
    - click "openbao-dedicated"
    - Add mapper → By configuration → Group Membership
        - Name : groups
        - Token claim : groups
        - Full path : OFF

- Create groups, Groups → Create group
    - devops-admin
    - team-backend  
    - team-frontend

- Create users
    - Username : openbao-admin
    - Email : openbao-admin@internal.com
    - assign user to group : devops-admin
        - Credentials tab → Set password → Temporary: OFF
    (and also create user for team-backend and team-frontend)

## 3. Configure OpenBao
- Configure Openbao OIDC
```sh
# Set token
ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('openbao-init-output.json')); print(d['root_token'])")
kubectl exec -n openbao openbao-0 -- bao login $ROOT_TOKEN

# Enable OIDC auth method
kubectl exec -n openbao openbao-0 -- bao auth enable oidc

# Configuration OIDC
CLIENT_SECRET="paste-client-secret-from-keycloak-here"

# http://172.28.0.124:31719/sso to your real keycloak url
kubectl exec -n openbao openbao-0 -- bao write auth/oidc/config \
  oidc_discovery_url="http://your-keycloak-url.com/sso/realms/openbao" \
  oidc_client_id="openbao" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role="default"
```

- Create policies/team
```sh
# Policy: devops-admin (allow all)
cat > /tmp/policy-admin.hcl <<'EOF'
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/*" {
  capabilities = ["read", "list"]
}
EOF
kubectl cp /tmp/policy-admin.hcl openbao/openbao-0:/tmp/policy-admin.hcl
kubectl exec -n openbao openbao-0 -- bao policy write devops-admin /tmp/policy-admin.hcl

# Policy: team-backend (access only path backend)
cat > /tmp/policy-backend.hcl <<'EOF'
path "secret/data/production/backend/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/production/backend/*" {
  capabilities = ["read", "list"]
}
EOF
kubectl cp /tmp/policy-backend.hcl openbao/openbao-0:/tmp/policy-backend.hcl
kubectl exec -n openbao openbao-0 -- bao policy write team-backend /tmp/policy-backend.hcl

# Policy: team-frontend (access only path frontend)
cat > /tmp/policy-frontend.hcl <<'EOF'
path "secret/data/production/frontend/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/production/frontend/*" {
  capabilities = ["read", "list"]
}
EOF
kubectl cp /tmp/policy-frontend.hcl openbao/openbao-0:/tmp/policy-frontend.hcl
kubectl exec -n openbao openbao-0 -- bao policy write team-frontend /tmp/policy-frontend.hcl

# Verify
kubectl exec -n openbao openbao-0 -- bao policy list
```

- Create OIDC roles in OpenBao
```sh
# Default role — for login, bound to all group
kubectl exec -n openbao openbao-0 -- bao write auth/oidc/role/default \
  allowed_redirect_uris="http://your-openbao-url.com/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  groups_claim="groups" \
  role_type="oidc" \
  token_ttl="8h" \
  token_policies="default"

# Verify OIDC config
kubectl exec -n openbao openbao-0 -- bao read auth/oidc/config
kubectl exec -n openbao openbao-0 -- bao read auth/oidc/role/default
```

- Bind OpenBao groups to the Keycloak groups
```sh
# take accessor OIDC
OIDC_ACCESSOR=$(kubectl exec -n openbao openbao-0 -- \
  bao auth list -format=json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['oidc/']['accessor'])")

echo "OIDC Accessor: $OIDC_ACCESSOR"

# Create internal group in OpenBao + bind to Keycloak group
# Group: devops-admin
kubectl exec -n openbao openbao-0 -- bao write identity/group \
  name="devops-admin" \
  type="external" \
  policies="devops-admin" \
  metadata=team="devops"

DEVOPS_GROUP_ID=$(kubectl exec -n openbao openbao-0 -- \
  bao read -format=json identity/group/name/devops-admin | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

kubectl exec -n openbao openbao-0 -- bao write identity/group-alias \
  name="devops-admin" \
  canonical_id="$DEVOPS_GROUP_ID" \
  mount_accessor="$OIDC_ACCESSOR"

# Group: team-backend
kubectl exec -n openbao openbao-0 -- bao write identity/group \
  name="team-backend" \
  type="external" \
  policies="team-backend" \
  metadata=team="backend"

BACKEND_GROUP_ID=$(kubectl exec -n openbao openbao-0 -- \
  bao read -format=json identity/group/name/team-backend | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

kubectl exec -n openbao openbao-0 -- bao write identity/group-alias \
  name="team-backend" \
  canonical_id="$BACKEND_GROUP_ID" \
  mount_accessor="$OIDC_ACCESSOR"

# Group: team-frontend
kubectl exec -n openbao openbao-0 -- bao write identity/group \
  name="team-frontend" \
  type="external" \
  policies="team-frontend" \
  metadata=team="frontend"

FRONTEND_GROUP_ID=$(kubectl exec -n openbao openbao-0 -- \
  bao read -format=json identity/group/name/team-frontend | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

kubectl exec -n openbao openbao-0 -- bao write identity/group-alias \
  name="team-frontend" \
  canonical_id="$FRONTEND_GROUP_ID" \
  mount_accessor="$OIDC_ACCESSOR"

# Verify all groups
kubectl exec -n openbao openbao-0 -- bao list identity/group/name
```

- Test login via OpenBao UI
    - access to your OpenBao url : http://your-openbao-url.com
    - Method : OIDC
    - Role : default
    - Click on "klik Sign in with OIDC Provider" - would be redirect to keycloak login page
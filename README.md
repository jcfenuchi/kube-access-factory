# kubeconfig-factory

Versão em pt-BR: [README-PT-br.md](README-PT-br.md)

Helm chart that creates each project's namespaces and, for each access group, a ServiceAccount with a token, the Role for the chosen permission level and the RoleBinding. Once installed, the scripts in `scripts/` build one kubeconfig file per group, ready to hand over.

The folder is called `KUBECONFIG_FACTORY`; the chart and release name is `kubeconfig-factory`.

## Why it exists and when to use it

Without this chart, giving a project team access to a cluster ends one of two ways: handing over the administrator kubeconfig, which opens the whole cluster, or creating a ServiceAccount, Role and RoleBinding by hand for every request, each time with slightly different permissions. Here, access lives in a list in `values.yaml`. Each group gets one of five fixed levels, `helm upgrade` applies the change and the scripts generate the group's file. To see who has access to what, or to revoke access, you open and edit that list.

The weak spot is identity. Each group uses a single ServiceAccount token, shared by everyone in the group. The cluster audit log records the ServiceAccount, not who performed the action. Removing one person from a group means replacing the whole group's token (the procedure is in "Security and operational notes").

| Situation | Recommendation |
| :--- | :--- |
| Cluster without an integrated identity provider (OIDC, AD/LDAP via Dex, Rancher etc.) | Use this chart |
| Automation access (CI/CD pipelines, deploy tools) | Use this chart, with one group per tool |
| Cluster with an integrated identity provider, for people's access | Use the identity provider, which gives each person their own credential, with expiration and individual auditing. This chart's Roles can be reused with RoleBindings created by hand for the provider's groups, since the chart only generates bindings for ServiceAccounts |

## Permission levels

| Level | Binding | Permissions |
| :--- | :--- | :--- |
| `viewer` | `RoleBinding` | Read-only (`get`, `list`, `watch`) |
| `developer` | `RoleBinding` | Deploys and limited operations (pods, deployments, jobs, logs, exec) |
| `operator` | `RoleBinding` | Everything in `developer`, plus `secrets`, `configmaps`, `hpa` and `cronjobs` |
| `admin` | `RoleBinding` | Every resource in the namespace |
| `platform-admin` | `ClusterRoleBinding` | The whole cluster, via `cluster-admin` |

## Layout

```
KUBECONFIG_FACTORY/
├── Chart.yaml                          # Helm v2 chart metadata
├── values.yaml                         # Default configuration, with comments
├── values-production-example.yaml      # Multi-project example with every level
├── .helmignore                         # Files Helm ignores
├── README.md                           # This documentation (English)
├── README-PT-br.md                     # Documentation in Portuguese
├── templates/
│   ├── _helpers.tpl                    # Common labels and name helpers
│   ├── namespace.yaml                  # Creates the declared namespaces
│   ├── serviceaccount.yaml             # One ServiceAccount per group
│   ├── secret-token.yaml               # Secret with a long-lived token (K8s 1.24+)
│   ├── role.yaml                       # Predefined Roles (viewer/developer/operator/admin)
│   │                                   # Generated once per namespace, no duplicates
│   ├── rolebinding.yaml                # RoleBinding (namespace) or ClusterRoleBinding (cluster)
│   └── NOTES.txt                       # Post-install message with export commands
└── scripts/
    ├── export-kubeconfig.ps1           # Windows PowerShell script to export kubeconfigs
    └── export-kubeconfig.sh            # Bash script (Linux/macOS)
```

## Configuration

```yaml
cluster:
  name: "kubernetes-cluster"
  server: "https://k8s.empresa.com.br:6443"
  certificateAuthorityData: ""
  insecureSkipTlsVerify: true

namespaces:
  - name: "projeto-a"
    create: true
    labels:
      environment: "production"

groups:
  # Read-only
  - name: "k8s-projeto-a-viewers"
    namespace: "projeto-a"
    scope: "namespace"
    role: "viewer"

  # Deploys and limited operations
  - name: "k8s-projeto-a-developers"
    namespace: "projeto-a"
    scope: "namespace"
    role: "developer"

  # Extended operations
  - name: "k8s-projeto-a-operators"
    namespace: "projeto-a"
    scope: "namespace"
    role: "operator"

  # Namespace administration
  - name: "k8s-projeto-a-admins"
    namespace: "projeto-a"
    scope: "namespace"
    role: "admin"

  # Global cluster administration
  - name: "k8s-platform-admins"
    namespace: ""        # Ignored for cluster scope
    scope: "cluster"
    role: "platform-admin"
```

Every namespace with at least one group gets the four Roles (`kubeconfig-factory:viewer`, `kubeconfig-factory:developer` and so on) exactly once, however many groups use the same level.

> [!WARNING]
> No template or script reads the `cluster` block yet. Changing `server`, `name`, `certificateAuthorityData` or `insecureSkipTlsVerify` doesn't change the generated kubeconfigs. The endpoint comes from the `-Server` parameter (PowerShell) or the 3rd argument (Bash) and, without them, from the current `kubectl` context. The CA comes from the `ca.crt` field of each group's token Secret, with TLS verification always on. The cluster always shows up in the kubeconfig as `k8s-cluster`, so files from different clusters collide if merged into one.

## Installation and usage

### 1. Install in the cluster
```bash
helm upgrade --install kubeconfig-factory . -f values.yaml
```

### 2. Export the kubeconfigs

On Windows (PowerShell):
```powershell
# Export every group:
.\scripts\export-kubeconfig.ps1

# Export a single group:
.\scripts\export-kubeconfig.ps1 -GroupName "k8s-projeto-a-viewers"

# Set the API endpoint and the output folder:
.\scripts\export-kubeconfig.ps1 -Server "https://k8s.empresa.com.br:6443" -OutputDir ".\saida"
```

On Linux or macOS (Bash):
```bash
chmod +x scripts/export-kubeconfig.sh

# Export every group:
./scripts/export-kubeconfig.sh

# Export a single group:
./scripts/export-kubeconfig.sh "k8s-projeto-a-viewers"

# Positional arguments: <group> <output-folder> <api-endpoint>
# Use "" as the group to export all of them:
./scripts/export-kubeconfig.sh "" ./output-kubeconfigs "https://k8s.empresa.com.br:6443"
```

The Bash script writes the files with `600` permissions. PowerShell inherits the folder's permissions, so restrict access by hand if the folder is shared.

By default the files go to `./output-kubeconfigs/`:
```
output-kubeconfigs/
├── kubeconfig-k8s-projeto-a-viewers.yaml
├── kubeconfig-k8s-projeto-a-developers.yaml
├── kubeconfig-k8s-projeto-a-operators.yaml
├── kubeconfig-k8s-projeto-a-admins.yaml
└── kubeconfig-k8s-platform-admins.yaml
```

### 3. Hand the file to the group

Send each group the file with its name. The recipient can use it right away:

```bash
# Test the received kubeconfig:
kubectl --kubeconfig=kubeconfig-k8s-projeto-a-developers.yaml get pods

# Make it the default for the session:
export KUBECONFIG=kubeconfig-k8s-projeto-a-developers.yaml
kubectl get deployments
```

RBAC limits each kubeconfig to the group's namespace and level and blocks everything else. The exception is the `operator` level, explained below in "Security and operational notes".

## Checking what was created

```bash
# Check resources per namespace:
kubectl get sa,secrets,roles,rolebindings -n projeto-a

# Check ClusterRoleBindings created by the chart:
kubectl get clusterrolebindings | grep kubeconfig-factory

# See the details of a predefined Role:
kubectl describe role kubeconfig-factory:developer -n projeto-a
```

## Security and operational notes

### `operator` can become the namespace `admin`

The `operator` Role can read `secrets`, and the token Secrets of every group live in the application namespace, including `<admin-group>-token`. Anyone with the `operator` kubeconfig can read the `admin` token and use it. While the tokens live in that namespace, treat `operator` and `admin` as the same trust level, or don't create an `admin` group where there is an `operator` group.

### Tokens don't expire

Secrets of type `kubernetes.io/service-account-token` produce tokens with no expiration. To revoke a group's access, delete the Secret: the old token stops working immediately. Then run `helm upgrade` to create a new Secret and export the kubeconfig again:

```bash
kubectl delete secret k8s-projeto-a-developers-token -n projeto-a
helm upgrade --install kubeconfig-factory . -f values.yaml
./scripts/export-kubeconfig.sh "k8s-projeto-a-developers"
```

### The `platform-admin` token is a permanent `cluster-admin`

It lives in `kube-system` and gives full control of the cluster to whoever holds the file. Give this kubeconfig to as few people as possible and replace the token, using the procedure above, whenever someone leaves the team.

### `helm uninstall` deletes the namespaces

Namespaces with `create: true` belong to the release. Uninstalling the chart deletes those namespaces and everything in them, applications included. To remove only the access, take the groups out of `values.yaml` and run `helm upgrade`.

### `output-kubeconfigs/` holds tokens

The folder is in `.helmignore` and doesn't go into a `helm package`. Don't put it under version control; if the directory is in a Git repository, add `output-kubeconfigs/` to `.gitignore`.

### `viewer` and `developer` can't read `events`

For these levels, the event list at the end of `kubectl describe pod` comes out empty. Only `operator` and `admin` can read `events`.

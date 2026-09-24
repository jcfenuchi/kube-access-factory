# kubeconfig-factory

English version: [README.md](README.md)

Chart Helm que cria os namespaces de cada projeto e, para cada grupo de acesso, uma ServiceAccount com token, a Role do nível de permissão escolhido e o RoleBinding. Depois de instalado, os scripts em `scripts/` montam um arquivo kubeconfig por grupo, pronto para entregar.

A pasta se chama `KUBECONFIG_FACTORY`; o nome do chart e do release é `kubeconfig-factory`.

## Por que existe e quando usar

Sem este chart, dar acesso a uma equipe de projeto acaba em uma de duas saídas: entregar o kubeconfig de administrador, que abre o cluster inteiro, ou criar ServiceAccount, Role e RoleBinding à mão a cada pedido, cada vez com permissões um pouco diferentes. Aqui, os acessos ficam numa lista no `values.yaml`. Cada grupo recebe um de cinco níveis fixos, `helm upgrade` aplica a mudança e os scripts geram o arquivo do grupo. Para saber quem acessa o quê, ou para revogar um acesso, basta abrir e editar essa lista.

O ponto fraco é a identidade. Cada grupo usa um único token de ServiceAccount, compartilhado por todas as pessoas do grupo. O log de auditoria do cluster registra a ServiceAccount, e não quem fez a ação. Para tirar uma pessoa do grupo é preciso trocar o token do grupo inteiro (o procedimento está em "Cuidados de segurança e operação").

| Situação | Recomendação |
| :--- | :--- |
| Cluster sem provedor de identidade integrado (OIDC, AD/LDAP via Dex, Rancher etc.) | Use este chart |
| Acesso de automação (pipelines de CI/CD, ferramentas de deploy) | Use este chart, com um grupo por ferramenta |
| Cluster com provedor de identidade integrado, para acesso de pessoas | Use o provedor de identidade, que dá a cada pessoa uma credencial própria, com expiração e auditoria individual. As Roles deste chart podem ser reaproveitadas com RoleBindings criados à mão para os grupos do provedor, já que o chart só gera bindings para ServiceAccounts |

## Níveis de permissão

| Nível | Binding | Permissões |
| :--- | :--- | :--- |
| `viewer` | `RoleBinding` | Somente leitura (`get`, `list`, `watch`) |
| `developer` | `RoleBinding` | Deploy e operação limitada (pods, deployments, jobs, logs, exec) |
| `operator` | `RoleBinding` | Tudo do `developer`, mais `secrets`, `configmaps`, `hpa` e `cronjobs` |
| `admin` | `RoleBinding` | Todos os recursos do namespace |
| `platform-admin` | `ClusterRoleBinding` | O cluster inteiro, via `cluster-admin` |

## Estrutura

```
KUBECONFIG_FACTORY/
├── Chart.yaml                          # Metadados do Chart Helm v2
├── values.yaml                         # Configuração padrão com comentários
├── values-production-example.yaml      # Exemplo multi-projeto com todos os níveis
├── .helmignore                         # Arquivos ignorados pelo Helm
├── README.md                           # Documentação em inglês
├── README-PT-br.md                     # Esta documentação (português)
├── templates/
│   ├── _helpers.tpl                    # Labels comuns e helpers de nomes
│   ├── namespace.yaml                  # Criação dos namespaces declarados
│   ├── serviceaccount.yaml             # ServiceAccount por grupo
│   ├── secret-token.yaml               # Secret com token duradouro (K8s 1.24+)
│   ├── role.yaml                       # Roles predefinidas (viewer/developer/operator/admin)
│   │                                   # Geradas uma vez por namespace, sem duplicatas
│   ├── rolebinding.yaml                # RoleBinding (namespace) ou ClusterRoleBinding (cluster)
│   └── NOTES.txt                       # Mensagem pós-install com comandos de extração
└── scripts/
    ├── export-kubeconfig.ps1           # Script Windows PowerShell para extrair kubeconfigs
    └── export-kubeconfig.sh            # Script Bash (Linux/macOS)
```

## Configuração

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
  # Somente leitura
  - name: "k8s-projeto-a-viewers"
    namespace: "projeto-a"
    scope: "namespace"
    role: "viewer"

  # Deploy e operação limitada
  - name: "k8s-projeto-a-developers"
    namespace: "projeto-a"
    scope: "namespace"
    role: "developer"

  # Operação ampliada
  - name: "k8s-projeto-a-operators"
    namespace: "projeto-a"
    scope: "namespace"
    role: "operator"

  # Administração do namespace
  - name: "k8s-projeto-a-admins"
    namespace: "projeto-a"
    scope: "namespace"
    role: "admin"

  # Administração global do cluster
  - name: "k8s-platform-admins"
    namespace: ""        # Ignorado no escopo cluster
    scope: "cluster"
    role: "platform-admin"
```

Cada namespace com pelo menos um grupo recebe as quatro Roles (`kubeconfig-factory:viewer`, `kubeconfig-factory:developer` e assim por diante) uma vez só, por mais grupos que usem o mesmo nível.

> [!WARNING]
> Nenhum template nem script lê o bloco `cluster` por enquanto. Mudar `server`, `name`, `certificateAuthorityData` ou `insecureSkipTlsVerify` não altera os kubeconfigs gerados. O endpoint vem do parâmetro `-Server` (PowerShell) ou do 3º argumento (Bash) e, na falta deles, do contexto atual do `kubectl`. A CA sai do campo `ca.crt` da Secret de token de cada grupo, com a verificação TLS sempre ligada. O cluster aparece no kubeconfig sempre como `k8s-cluster`, então arquivos de clusters diferentes colidem se forem mesclados num só.

## Instalação e uso

### 1. Instalar no cluster
```bash
helm upgrade --install kubeconfig-factory . -f values.yaml
```

### 2. Exportar os kubeconfigs

No Windows (PowerShell):
```powershell
# Exportar todos os grupos:
.\scripts\export-kubeconfig.ps1

# Exportar somente um grupo:
.\scripts\export-kubeconfig.ps1 -GroupName "k8s-projeto-a-viewers"

# Informar o endpoint da API e a pasta de saída:
.\scripts\export-kubeconfig.ps1 -Server "https://k8s.empresa.com.br:6443" -OutputDir ".\saida"
```

No Linux ou macOS (Bash):
```bash
chmod +x scripts/export-kubeconfig.sh

# Exportar todos os grupos:
./scripts/export-kubeconfig.sh

# Exportar somente um grupo:
./scripts/export-kubeconfig.sh "k8s-projeto-a-viewers"

# Argumentos posicionais: <grupo> <pasta-de-saída> <endpoint-da-api>
# Use "" no grupo para exportar todos:
./scripts/export-kubeconfig.sh "" ./output-kubeconfigs "https://k8s.empresa.com.br:6443"
```

O script Bash grava os arquivos com permissão `600`. O PowerShell herda a permissão da pasta, então restrinja o acesso à mão se ela for compartilhada.

Por padrão os arquivos vão para `./output-kubeconfigs/`:
```
output-kubeconfigs/
├── kubeconfig-k8s-projeto-a-viewers.yaml
├── kubeconfig-k8s-projeto-a-developers.yaml
├── kubeconfig-k8s-projeto-a-operators.yaml
├── kubeconfig-k8s-projeto-a-admins.yaml
└── kubeconfig-k8s-platform-admins.yaml
```

### 3. Entregar ao grupo

Envie a cada grupo o arquivo com o nome dele. Quem recebe já pode usar:

```bash
# Testar o kubeconfig recebido:
kubectl --kubeconfig=kubeconfig-k8s-projeto-a-developers.yaml get pods

# Definir como padrão na sessão:
export KUBECONFIG=kubeconfig-k8s-projeto-a-developers.yaml
kubectl get deployments
```

O RBAC limita cada kubeconfig ao namespace e ao nível do grupo, e bloqueia o resto. A exceção é o nível `operator`, explicada logo abaixo em "Cuidados de segurança e operação".

## Conferindo o que foi criado

```bash
# Verificar recursos por namespace:
kubectl get sa,secrets,roles,rolebindings -n projeto-a

# Verificar ClusterRoleBindings criados pelo chart:
kubectl get clusterrolebindings | grep kubeconfig-factory

# Ver detalhes de uma Role predefinida:
kubectl describe role kubeconfig-factory:developer -n projeto-a
```

## Cuidados de segurança e operação

### `operator` consegue virar `admin` do namespace

A Role `operator` lê `secrets`, e as Secrets de token de todos os grupos ficam no namespace da aplicação, inclusive a `<grupo-admin>-token`. Quem tem o kubeconfig de `operator` pode ler o token do `admin` e usá-lo. Enquanto os tokens ficarem nesse namespace, trate `operator` e `admin` como o mesmo nível de confiança, ou não crie grupo `admin` onde houver grupo `operator`.

### Os tokens não expiram

Secrets do tipo `kubernetes.io/service-account-token` geram tokens sem validade. Para revogar o acesso de um grupo, apague a Secret: o token antigo para de funcionar na hora. Em seguida, rode `helm upgrade` para criar uma Secret nova e exporte o kubeconfig outra vez:

```bash
kubectl delete secret k8s-projeto-a-developers-token -n projeto-a
helm upgrade --install kubeconfig-factory . -f values.yaml
./scripts/export-kubeconfig.sh "k8s-projeto-a-developers"
```

### O token de `platform-admin` é um `cluster-admin` permanente

Ele fica em `kube-system` e dá controle total do cluster a quem tiver o arquivo. Entregue esse kubeconfig ao menor número de pessoas possível e troque o token, pelo procedimento acima, sempre que alguém sair da equipe.

### `helm uninstall` apaga os namespaces

Os namespaces com `create: true` pertencem ao release. Desinstalar o chart apaga esses namespaces e tudo o que estiver neles, aplicações incluídas. Para retirar só os acessos, tire os grupos do `values.yaml` e rode `helm upgrade`.

### `output-kubeconfigs/` guarda tokens

A pasta está no `.helmignore` e não entra num `helm package`. Não a coloque em controle de versão; se o diretório estiver num repositório Git, acrescente `output-kubeconfigs/` ao `.gitignore`.

### `viewer` e `developer` não leem `events`

Para esses níveis, a lista de eventos no fim de `kubectl describe pod` sai vazia. Só `operator` e `admin` têm acesso a `events`.

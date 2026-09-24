<#
.SYNOPSIS
    Exporta arquivos Kubeconfig isolados por grupo de acesso, a partir dos recursos
    criados pelo Helm Chart Kubeconfig Factory.

.DESCRIPTION
    O script consulta o cluster via kubectl para listar todas as Secrets do tipo
    'kubernetes.io/service-account-token' criadas pelo chart, extrai o token e a CA,
    e gera arquivos kubeconfig individuais prontos para envio a cada grupo de acesso.

.PARAMETER GroupName
    Nome do grupo (campo 'name' no values.yaml) a exportar. Se omitido, exporta todos.

.PARAMETER Server
    URL da API do Kubernetes. Se omitido, tenta detectar do contexto ativo do kubectl.

.PARAMETER OutputDir
    Diretório de saída dos arquivos. Padrão: './output-kubeconfigs'

.EXAMPLE
    # Exportar todos os grupos:
    .\scripts\export-kubeconfig.ps1

    # Exportar somente o grupo de viewers do projeto-a:
    .\scripts\export-kubeconfig.ps1 -GroupName "k8s-projeto-a-viewers"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GroupName = "",

    [Parameter(Mandatory = $false)]
    [string]$Server = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "./output-kubeconfigs"
)

# ── Criar diretório de saída ──────────────────────────────────────────────────
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# ── Detectar endpoint do cluster ──────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = (kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}').Trim()
    if ([string]::IsNullOrWhiteSpace($Server)) { $Server = "https://127.0.0.1:6443" }
}
Write-Host "`n🔗 Endpoint do cluster: $Server" -ForegroundColor Cyan

# ── Buscar todos os tokens criados pelo kubeconfig-factory ────────────────────
Write-Host "🔍 Buscando secrets com label 'app.kubernetes.io/component=token-secret'..." -ForegroundColor Cyan

$secretsJson = kubectl get secrets -A `
    -l "app.kubernetes.io/component=token-secret" `
    -o json | ConvertFrom-Json

if ($null -eq $secretsJson.items -or $secretsJson.items.Count -eq 0) {
    Write-Warning "Nenhuma Secret do kubeconfig-factory encontrada no cluster."
    Write-Host "Execute primeiro: helm upgrade --install kubeconfig-factory . -f values.yaml" -ForegroundColor Yellow
    exit 1
}

$exported = 0

foreach ($item in $secretsJson.items) {
    $group    = $item.metadata.labels.'kubeconfig-factory/group'
    $scope    = $item.metadata.labels.'kubeconfig-factory/scope'
    $role     = $item.metadata.labels.'kubeconfig-factory/role'
    $ns       = $item.metadata.namespace
    $secName  = $item.metadata.name

    # Filtro por nome de grupo se informado
    if (-not [string]::IsNullOrWhiteSpace($GroupName) -and $group -ne $GroupName) { continue }

    Write-Host "`n──────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "📦 Grupo     : $group" -ForegroundColor Yellow
    Write-Host "   Nível     : $role"
    Write-Host "   Escopo    : $scope"
    Write-Host "   Namespace : $ns"

    # Obter token (base64 → string)
    $tokenB64 = (kubectl get secret $secName -n $ns -o jsonpath='{.data.token}').Trim()
    if ([string]::IsNullOrWhiteSpace($tokenB64)) {
        Write-Warning "   ⚠️  Token ainda não gerado pelo cluster para '$secName'. Aguarde alguns segundos e tente novamente."
        continue
    }
    $tokenBytes = [System.Convert]::FromBase64String($tokenB64)
    $token = [System.Text.Encoding]::UTF8.GetString($tokenBytes)

    # Obter CA em base64 (mantém base64 conforme spec kubeconfig)
    $caData = (kubectl get secret $secName -n $ns -o jsonpath='{.data.ca\.crt}').Trim()

    $clusterName = "k8s-cluster"
    $contextName = "$group@$clusterName"
    $contextNs   = if ($scope -eq "cluster") { "default" } else { $ns }
    $outFile     = Join-Path $OutputDir "kubeconfig-$group.yaml"

    $kubeconfigContent = @"
# Kubeconfig gerado pelo Helm Chart Kubeconfig Factory
# Grupo : $group
# Nível : $role  |  Escopo: $scope
# ──────────────────────────────────────────────────────
apiVersion: v1
kind: Config
preferences: {}
clusters:
- cluster:
    certificate-authority-data: $caData
    server: $Server
  name: $clusterName
contexts:
- context:
    cluster: $clusterName
    namespace: $contextNs
    user: $group
  name: $contextName
current-context: $contextName
users:
- name: $group
  user:
    token: $token
"@

    Set-Content -Path $outFile -Value $kubeconfigContent -Encoding UTF8
    Write-Host "   ✅ Kubeconfig gerado: $outFile" -ForegroundColor Green
    $exported++
}

Write-Host "`n──────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "🎉 Concluído! $exported arquivo(s) gerado(s) em '$OutputDir'." -ForegroundColor Green
Write-Host "`nUso: kubectl --kubeconfig=<arquivo>.yaml get pods" -ForegroundColor DarkGray

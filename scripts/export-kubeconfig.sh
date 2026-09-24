#!/usr/bin/env bash
# ==============================================================================
# Kubeconfig Factory — Script de Exportação por Grupo (Bash)
# ==============================================================================
# Uso:
#   ./scripts/export-kubeconfig.sh                          # Exporta todos
#   ./scripts/export-kubeconfig.sh k8s-projeto-a-viewers   # Exporta um grupo
# ==============================================================================

set -euo pipefail
# Os kubeconfigs gerados contêm tokens: só o dono do arquivo pode ler.
umask 077

GROUP_FILTER="${1:-}"
OUTPUT_DIR="${2:-./output-kubeconfigs}"
SERVER="${3:-}"

mkdir -p "$OUTPUT_DIR"

if [ -z "$SERVER" ]; then
    SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://127.0.0.1:6443")
fi
echo -e "\n🔗 Endpoint do cluster: $SERVER"

echo "🔍 Buscando secrets com label 'app.kubernetes.io/component=token-secret'..."
SECRETS=$(kubectl get secrets -A \
    -l "app.kubernetes.io/component=token-secret" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{.metadata.labels.kubeconfig-factory/group}{"\t"}{.metadata.labels.kubeconfig-factory/scope}{"\t"}{.metadata.labels.kubeconfig-factory/role}{"\n"}{end}')

if [ -z "$SECRETS" ]; then
    echo "⚠️  Nenhuma secret do kubeconfig-factory encontrada no cluster."
    echo "   Execute: helm upgrade --install kubeconfig-factory . -f values.yaml"
    exit 1
fi

EXPORTED=0

while IFS=$'\t' read -r SECRET_NAME NAMESPACE GROUP SCOPE ROLE; do
    [ -z "$GROUP" ] && continue

    if [ -n "$GROUP_FILTER" ] && [ "$GROUP" != "$GROUP_FILTER" ]; then
        continue
    fi

    echo -e "\n──────────────────────────────────────────────────────────"
    echo -e "📦 Grupo     : $GROUP"
    echo    "   Nível     : $ROLE"
    echo    "   Escopo    : $SCOPE"
    echo    "   Namespace : $NAMESPACE"

    TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 --decode 2>/dev/null || true)
    if [ -z "$TOKEN" ]; then
        echo "   ⚠️  Token ainda não gerado. Aguarde alguns segundos e tente novamente."
        continue
    fi

    CA_DATA=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')
    CONTEXT_NS=$([ "$SCOPE" = "cluster" ] && echo "default" || echo "$NAMESPACE")
    CLUSTER_NAME="k8s-cluster"
    OUT_FILE="$OUTPUT_DIR/kubeconfig-$GROUP.yaml"

    cat <<EOF > "$OUT_FILE"
# Kubeconfig gerado pelo Helm Chart Kubeconfig Factory
# Grupo : $GROUP
# Nível : $ROLE  |  Escopo: $SCOPE
# ──────────────────────────────────────────────────────
apiVersion: v1
kind: Config
preferences: {}
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${CONTEXT_NS}
    user: ${GROUP}
  name: ${GROUP}@${CLUSTER_NAME}
current-context: ${GROUP}@${CLUSTER_NAME}
users:
- name: ${GROUP}
  user:
    token: ${TOKEN}
EOF

    echo "   ✅ Kubeconfig gerado: $OUT_FILE"
    EXPORTED=$((EXPORTED + 1))

done <<< "$SECRETS"

echo -e "\n──────────────────────────────────────────────────────────"
echo -e "🎉 Concluído! $EXPORTED arquivo(s) gerado(s) em '$OUTPUT_DIR'."
echo -e "   Uso: kubectl --kubeconfig=<arquivo>.yaml get pods"

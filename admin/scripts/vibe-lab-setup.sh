#!/usr/bin/env bash
# =============================================================================
# vibe-lab-setup.sh — Ollama 기반 vibe-lab 클러스터 설치
#
# CyberSecurity-1G에서 실행
# 모든 GPU 서버에 Ollama를 설치하고 모델을 다운로드합니다.
#
# 사용법:
#   chmod +x vibe-lab-setup.sh
#   ./vibe-lab-setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

SSH="ssh -p 8510 -o ConnectTimeout=5 -o BatchMode=yes"

# ── 서버별 모델 배치 설정 ──
# 형식: "서버|모델|설명|OLLAMA_MODELS경로(옵션)"
# OLLAMA_MODELS가 지정된 서버는 해당 경로에 모델을 저장합니다.
declare -a DEPLOYMENTS=(
    "8asus|qwen3-coder-next|주력 코딩 (80B MoE)|"
    "CyberSecurity-2G|qwq:32b|추론/설계 (32B)|/media1/ollama/models"
)

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  vibe-lab Ollama 클러스터 설치"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  배치 계획:"
for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"
    if [ -n "$models_path" ]; then
        echo "    $server → $model ($desc) [모델경로: $models_path]"
    else
        echo "    $server → $model ($desc)"
    fi
done
echo ""

# ── Step 1: SSH 연결 확인 ──
info "SSH 연결 확인 중..."

all_ok=true
for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"
    if $SSH "$server" "echo ok" &>/dev/null; then
        ok "  $server"
    else
        err "  $server — SSH 연결 실패 (포트 8510)"
        all_ok=false
    fi
done

if [ "$all_ok" = false ]; then
    echo ""
    warn "일부 서버에 SSH 연결이 안 됩니다."
    warn "SSH 키 설정을 확인하세요:"
    echo "  ssh-copy-id -p 8510 <서버>"
    echo ""
    read -rp "연결된 서버만 계속 진행하시겠습니까? (y/N): " cont
    if [[ ! "$cont" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ── Step 2: Ollama 설치 ──
info "Ollama 설치 중..."

for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"

    # 이미 설치되어 있는지 확인
    ollama_ver=$($SSH "$server" "ollama --version 2>/dev/null" || echo "")
    if [ -n "$ollama_ver" ]; then
        ok "  $server — 이미 설치됨 ($ollama_ver)"
    else
        info "  $server — 설치 중..."
        $SSH "$server" "curl -fsSL https://ollama.com/install.sh | sh" 2>/dev/null
        if $SSH "$server" "ollama --version" &>/dev/null; then
            ok "  $server — 설치 완료"
        else
            err "  $server — 설치 실패"
            continue
        fi
    fi
done

# ── Step 3: Ollama 서비스 시작 (외부 접근 허용) ──
info "Ollama 서비스 시작 중..."

for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"

    # systemd 서비스 환경 설정
    if [ -n "$models_path" ]; then
        override_content="[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0\"\nEnvironment=\"OLLAMA_MODELS=${models_path}\""
        $SSH "$server" "sudo mkdir -p ${models_path} && sudo chown ollama:ollama ${models_path}" 2>/dev/null
    else
        override_content="[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0\""
    fi
    $SSH "$server" "sudo mkdir -p /etc/systemd/system/ollama.service.d && \
        printf '${override_content}' | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null && \
        sudo systemctl daemon-reload && \
        sudo systemctl enable ollama && \
        sudo systemctl restart ollama" 2>/dev/null

    # 서비스 시작 확인
    sleep 2
    if $SSH "$server" "curl -sf http://localhost:11434/api/tags" &>/dev/null; then
        ok "  $server — Ollama 서비스 실행 중 (:11434)"
    else
        warn "  $server — Ollama 서비스 시작 대기 중..."
        sleep 5
        if $SSH "$server" "curl -sf http://localhost:11434/api/tags" &>/dev/null; then
            ok "  $server — Ollama 서비스 실행 확인"
        else
            err "  $server — Ollama 서비스 시작 실패"
        fi
    fi
done

# ── Step 4: 모델 다운로드 ──
info "모델 다운로드 중 (시간이 걸릴 수 있습니다)..."

for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"

    pull_env=""
    [ -n "$models_path" ] && pull_env="OLLAMA_MODELS=${models_path} "

    # 이미 다운로드되어 있는지 확인
    if $SSH "$server" "${pull_env}ollama list 2>/dev/null | grep -q '${model%%:*}'"; then
        ok "  $server — $model 이미 다운로드됨"
    else
        info "  $server — $model 다운로드 중..."
        if $SSH "$server" "${pull_env}ollama pull $model" 2>&1 | tail -1; then
            ok "  $server — $model 다운로드 완료"
        else
            err "  $server — $model 다운로드 실패"
        fi
    fi
done

# ── Step 5: 멀티 인스턴스 설정 ──
info "멀티 인스턴스 설정 중..."

# 8asus: GPU 페어별 qwen3-coder-next 인스턴스 (GPU 0-5, 3인스턴스 full GPU)
# GPU 6-7은 DL 개발용으로 예약
info "  8asus — qwen3-coder-next 3개 인스턴스 설정 중 (GPU 페어 0-1/2-3/4-5)..."

ssh -p 8510 8asus "sudo systemctl stop ollama 2>/dev/null; sudo systemctl disable ollama 2>/dev/null" || true

ssh -p 8510 8asus "sudo tee /etc/systemd/system/ollama-pair@.service > /dev/null" << 'UNIT'
[Unit]
Description=vibe-lab Ollama GPU-pair %i
After=network.target

[Service]
Type=simple
User=ollama
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"
ExecStart=/bin/bash -c 'CUDA_VISIBLE_DEVICES=$((%i*2)),$((  %i*2+1)) OLLAMA_HOST=0.0.0.0:$((11434+%i)) exec /usr/local/bin/ollama serve'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

ssh -p 8510 8asus "sudo systemctl daemon-reload"
for i in 0 1 2; do
    PORT=$(( 11434 + i ))
    ssh -p 8510 8asus "sudo systemctl enable ollama-pair@${i} && sudo systemctl start ollama-pair@${i}" 2>/dev/null
    ssh -p 8510 8asus "sudo ufw allow ${PORT}/tcp 2>/dev/null || sudo iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null" || true
    ok "    GPU 페어 $i (GPU $((i*2))-$((i*2+1)), 포트 ${PORT}) 시작됨"
done

# ── Step 6: 방화벽 확인 (포트 11434) ──
info "방화벽 확인 중 (포트 11434)..."

for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"

    # cyber1에서 접근 가능한지 확인
    if curl -sf --connect-timeout 3 "http://${server}:11434/api/tags" &>/dev/null; then
        ok "  $server:11434 — 접근 가능"
    else
        warn "  $server:11434 — 접근 불가"
        info "  → 방화벽 설정 시도 중..."
        $SSH "$server" "sudo ufw allow 11434/tcp 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 11434 -j ACCEPT 2>/dev/null" || true

        sleep 1
        if curl -sf --connect-timeout 3 "http://${server}:11434/api/tags" &>/dev/null; then
            ok "  $server:11434 — 방화벽 해제됨"
        else
            warn "  $server:11434 — 수동으로 방화벽을 확인하세요"
        fi
    fi
done

# ── Step 7: Tool Calling 테스트 ──
info "Tool Calling 테스트 중..."

for entry in "${DEPLOYMENTS[@]}"; do
    IFS='|' read -r server model desc models_path <<< "$entry"

    response=$(curl -sf --connect-timeout 15 "http://${server}:11434/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ollama" \
        -H "anthropic-version: 2023-06-01" \
        -d "{
            \"model\": \"${model}\",
            \"max_tokens\": 256,
            \"tools\": [{
                \"name\": \"bash\",
                \"description\": \"Run a bash command\",
                \"input_schema\": {
                    \"type\": \"object\",
                    \"properties\": {
                        \"command\": {\"type\": \"string\"}
                    },
                    \"required\": [\"command\"]
                }
            }],
            \"messages\": [{\"role\": \"user\", \"content\": \"Run ls to list files\"}]
        }" 2>/dev/null || echo "")

    if echo "$response" | grep -q "tool_use"; then
        ok "  $server ($model) — tool calling 정상"
    elif [ -z "$response" ]; then
        warn "  $server ($model) — 응답 없음 (모델 로딩 중일 수 있음)"
    else
        warn "  $server ($model) — tool_use 없음 (응답은 있음)"
    fi
done

# ── 완료 ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  ${GREEN}설치 완료!${NC}"
echo ""
echo "  사용법:"
echo -e "    ${CYAN}claude-local${NC}    → Qwen3-Coder-Next LB (8asus GPU 0-5, 3인스턴스 full GPU)"
echo -e "    ${CYAN}claude-reason${NC}   → cyber2 QwQ-32B (추론/설계)"
echo -e "    ${CYAN}claude-cloud${NC}    → 유료 Claude API"
echo ""
echo "  클러스터 상태 확인:"
echo "    ./vibe-lab-check.sh"
echo ""
echo "  다음 단계:"
echo "    사용자 워크스테이션에서 vibe-lab-init.sh 실행"
echo "═══════════════════════════════════════════════════════"
echo ""

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
        # ollama.com/install.sh는 구 버전 URL(.tgz)을 참조해 실패할 수 있으므로
        # GitHub releases에서 직접 다운로드
        OLLAMA_VER=$($SSH "$server" "curl -sf https://api.github.com/repos/ollama/ollama/releases/latest | python3 -c \"import sys,json; print(json.load(sys.stdin)['tag_name'])\" 2>/dev/null || echo 'v0.30.6'")
        $SSH "$server" "curl -fsSL https://github.com/ollama/ollama/releases/download/${OLLAMA_VER}/ollama-linux-amd64.tar.zst -o /tmp/ollama.tar.zst && \
            sudo tar --use-compress-program=unzstd -xf /tmp/ollama.tar.zst -C /usr/local && \
            sudo mkdir -p /usr/local/lib/ollama && \
            rm -f /tmp/ollama.tar.zst" 2>/dev/null
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

# 8asus: GPU 0-1-2 (triple@0) / GPU 3-4-5 (triple@1) — qwen3-coder-next 80B 각각
# GPU 6-7은 DL 개발용으로 예약
info "  8asus — GPU 0-2: qwen3-coder-next 80B (triple@0), GPU 3-5: qwen3-coder-next 80B (triple@1)..."

ssh -p 8510 8asus "sudo systemctl stop ollama 2>/dev/null; sudo systemctl disable ollama 2>/dev/null
  sudo systemctl stop 'ollama-pair@*' 'ollama-triple' 'ollama-single@*' 2>/dev/null
  sudo systemctl disable 'ollama-pair@0' 'ollama-pair@1' 'ollama-pair@2' 'ollama-triple' 2>/dev/null
  sudo systemctl disable 'ollama-single@3' 'ollama-single@4' 'ollama-single@5' 2>/dev/null" || true

# triple@ 템플릿: instance 0 → GPU 0-1-2 port 11434, instance 1 → GPU 3-4-5 port 11435
ssh -p 8510 8asus "sudo tee /etc/systemd/system/ollama-triple@.service > /dev/null" << 'UNIT'
[Unit]
Description=vibe-lab Ollama GPU-triple %i (qwen3-coder-next 80B)
After=network.target

[Service]
Type=simple
User=ollama
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"
# Claude Code는 58개 툴 스키마 + 시스템 프롬프트로 ~26k 토큰을 보냄.
# 16384이면 입력이 잘려 툴 호출이 깨지므로 32768로 설정 (Q5_K_M 80B + KV 캐시 ≈ 61GB, GPU 3개 73.5GB 내).
Environment="OLLAMA_CONTEXT_LENGTH=32768"
Environment="OLLAMA_FLASH_ATTN=1"
ExecStart=/bin/bash -c 'CUDA_VISIBLE_DEVICES=$((%i*3)),$((  %i*3+1)),$((  %i*3+2)) OLLAMA_HOST=0.0.0.0:$((11434+%i)) exec /usr/local/bin/ollama serve'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

ssh -p 8510 8asus "sudo systemctl daemon-reload"

for i in 0 1; do
    PORT=$(( 11434 + i ))
    GPU_START=$(( i * 3 ))
    ssh -p 8510 8asus "sudo systemctl enable ollama-triple@${i} && sudo systemctl start ollama-triple@${i}"
    ssh -p 8510 8asus "sudo ufw allow ${PORT}/tcp 2>/dev/null" || true
    ok "    GPU triple@${i} (GPU ${GPU_START}-$((GPU_START+2)), 포트 ${PORT}) 시작됨"
done

# CyberSecurity-2G: GPU 0은 기존 ollama.service(qwq:32b), GPU 1에 두 번째 인스턴스 추가
info "  CyberSecurity-2G — GPU 1에 qwq:32b 두 번째 인스턴스 설정 중 (포트 11435)..."

# 기존 ollama.service에 CUDA_VISIBLE_DEVICES=0 명시 (GPU 1과 충돌 방지)
ssh -p 8510 CyberSecurity-2G "grep -q 'CUDA_VISIBLE_DEVICES=0' /etc/systemd/system/ollama.service || sudo sed -i '/Environment=\"PATH=/a Environment=\"CUDA_VISIBLE_DEVICES=0\"' /etc/systemd/system/ollama.service"

ssh -p 8510 CyberSecurity-2G "sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null" << 'UNIT'
[Unit]
Description=vibe-lab Ollama GPU-1 (qwq:32b second instance)
After=network.target

[Service]
Type=simple
User=ollama
Environment="OLLAMA_MODELS=/media1/ollama/models"
Environment="OLLAMA_CONTEXT_LENGTH=16384"
Environment="OLLAMA_FLASH_ATTN=1"
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:11435"
ExecStart=/usr/local/bin/ollama serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

ssh -p 8510 CyberSecurity-2G "sudo systemctl daemon-reload && sudo ufw allow 11435/tcp 2>/dev/null || true"
ssh -p 8510 CyberSecurity-2G "sudo systemctl enable ollama-gpu1 && sudo systemctl restart ollama && sudo systemctl start ollama-gpu1"
ok "    CyberSecurity-2G GPU 1 (포트 11435) 시작됨"

# ── Step 6: LiteLLM 로드밸런서 설치 (로컬 머신) ──
info "LiteLLM 로드밸런서 설치 중 (로컬)..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITELLM_CONFIG="$(realpath "$SCRIPT_DIR/../litellm/config.yaml")"
LITELLM_WORKDIR="$(realpath "$SCRIPT_DIR/../litellm")"
CURRENT_USER="$(whoami)"

# conda env + litellm 설치
# conda env list로 실제 경로를 찾아 사용 (CONDA_BASE/envs와 다를 수 있음)
_find_conda_env() {
    conda env list 2>/dev/null | awk '/litellm-vibe/ {print $NF}'
}
LITELLM_ENV_PATH="$(_find_conda_env)"

if [ -z "$LITELLM_ENV_PATH" ]; then
    info "  litellm-vibe conda 환경 생성 중..."
    conda create -n litellm-vibe python=3.11 -y -q
    LITELLM_ENV_PATH="$(_find_conda_env)"
fi

LITELLM_BIN="${LITELLM_ENV_PATH}/bin/litellm"

if [ ! -f "$LITELLM_BIN" ]; then
    info "  litellm 설치 중..."
    "${LITELLM_ENV_PATH}/bin/pip" install -q "litellm[proxy]"
    ok "  litellm 설치 완료"
else
    ok "  litellm-vibe 이미 설치됨 ($($LITELLM_BIN --version 2>/dev/null || echo 'unknown'))"
fi

# systemd 서비스 파일 생성
sudo tee /etc/systemd/system/litellm-vibe.service > /dev/null << SVCEOF
[Unit]
Description=vibe-lab LiteLLM Load Balancer
After=network.target

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${LITELLM_WORKDIR}
ExecStart=${LITELLM_BIN} \\
  --config ${LITELLM_CONFIG} \\
  --port 4000 \\
  --host 0.0.0.0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable litellm-vibe
sudo systemctl restart litellm-vibe

sleep 3
if curl -sf --max-time 5 http://localhost:4000/health -H "Authorization: Bearer vibe-lab" &>/dev/null; then
    ok "  LiteLLM :4000 — 실행 중"
else
    warn "  LiteLLM :4000 — 아직 시작 중 (로그: journalctl -u litellm-vibe)"
fi

# ── Step 7: 방화벽 확인 (포트 11434) ──
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

# ── Step 8: Tool Calling 테스트 ──
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

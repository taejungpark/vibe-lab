#!/usr/bin/env bash
# =============================================================================
# vibe-lab-init.sh — 사용자 워크스테이션 설정
# Ollama 기반 vibe-lab 환경 초기 설정
#
# 사용법:
#   chmod +x vibe-lab-init.sh
#   ./vibe-lab-init.sh          # sudo 없이 실행!
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SRC="${SCRIPT_DIR}/agents"
COMMANDS_SRC="${SCRIPT_DIR}/commands"
SHELL_RC="$HOME/.bashrc"

# zsh 지원
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "$SHELL" 2>/dev/null)" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
fi

# ── 서버 설정 ──
LITELLM_SERVER="${VIBE_LITELLM:-CyberSecurity-1G}"       # LiteLLM 로드밸런서 실행 서버
REASONING_SERVER="${VIBE_REASONING:-CyberSecurity-2G}"  # 추론
OLLAMA_PORT="11434"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  vibe-lab 사용자 설정 (Ollama)"
echo "  Shell: ${SHELL_RC}"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Claude Code 확인 ──
info "Claude Code 확인 중..."

if command -v claude &> /dev/null; then
    claude_ver=$(claude --version 2>/dev/null || echo "unknown")
    ok "Claude Code ${claude_ver}"
else
    info "Claude Code 설치 중..."
    if command -v npm &> /dev/null; then
        npm install -g @anthropic-ai/claude-code 2>/dev/null || {
            warn "npm 전역 설치 실패 — sudo로 재시도"
            sudo npm install -g @anthropic-ai/claude-code
        }
    else
        err "Node.js/npm이 설치되어 있지 않습니다."
        echo "  설치: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        echo "         sudo apt-get install -y nodejs"
        exit 1
    fi

    if command -v claude &> /dev/null; then
        ok "Claude Code 설치 완료"
    else
        err "Claude Code 설치 실패. 수동으로 설치하세요."
        exit 1
    fi
fi

# ── Step 2: 서버 연결 확인 ──
info "서버 연결 확인 중..."

if curl -sf --connect-timeout 3 "http://${LITELLM_SERVER}:4000/health" -H "Authorization: Bearer vibe-lab" &>/dev/null; then
    ok "  LiteLLM LB (${LITELLM_SERVER}:4000)"
else
    warn "  LiteLLM LB (${LITELLM_SERVER}:4000) — 연결 실패"
fi

if curl -sf --connect-timeout 3 "http://${REASONING_SERVER}:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    ok "  ${REASONING_SERVER}:${OLLAMA_PORT} (추론/설계)"
else
    warn "  ${REASONING_SERVER}:${OLLAMA_PORT} (추론/설계) — 연결 실패"
fi

# ── Step 3: API 키 입력 (유료 Claude용) ──
info "Anthropic API 키 설정 (유료 Claude 모델용)..."

existing_key=""
if [ -f "$SHELL_RC" ]; then
    existing_key=$(grep -oP 'ANTHROPIC_API_KEY="\K[^"]+' "$SHELL_RC" 2>/dev/null | head -1 || echo "")
fi

if [ -n "$existing_key" ] && [ "$existing_key" != "dummy" ] && [ "$existing_key" != "ollama" ]; then
    ok "기존 API 키 발견 (${existing_key:0:12}...)"
    read -rp "  변경하시겠습니까? (y/N): " change_key
    if [[ "$change_key" =~ ^[Yy]$ ]]; then
        read -rp "  새 Anthropic API 키: " ANTHROPIC_API_KEY
    else
        ANTHROPIC_API_KEY="$existing_key"
    fi
else
    echo ""
    echo "  유료 Claude 모델(claude-cloud)을 사용하려면 API 키가 필요합니다."
    echo "  로컬 모델(claude-local)만 사용하려면 Enter를 누르세요."
    echo ""
    read -rp "  API 키 (Enter로 건너뛰기): " ANTHROPIC_API_KEY
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    ANTHROPIC_API_KEY="skip"
    warn "API 키 미설정 — claude-cloud 사용 불가 (로컬 모델은 정상)"
fi

# ── Step 4: Shell alias 설정 ──
info "Shell alias 설정 중..."

if [ -f "$SHELL_RC" ]; then
    sed -i '/# >>> vibe-lab 설정/,/# <<< vibe-lab 설정/d' "$SHELL_RC"
fi

# claude-cloud alias (API 키가 있을 때만)
if [ "$ANTHROPIC_API_KEY" = "skip" ]; then
    CLOUD_ALIAS="# claude-cloud — API 키 미설정 (vibe-lab-init.sh 재실행으로 설정 가능)"
else
    CLOUD_ALIAS="alias claude-cloud='ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\" claude'"
fi

cat >> "$SHELL_RC" << ALIASES

# >>> vibe-lab 설정 (자동 생성 — $(date +%Y-%m-%d)) >>>

# 유료 Claude 모델 (Anthropic API 직접 연결)
${CLOUD_ALIAS}

# ── LiteLLM 로드밸런서 설정 ──
LITELLM_URL="http://${LITELLM_SERVER}:4000"
LITELLM_KEY="vibe-lab"

# 로컬 모델 — qwen3-coder-next 80B 로드밸런싱 (8asus GPU 0-2 / 3-5, 최대 2명 동시, ~66 t/s)
alias claude-local='ANTHROPIC_AUTH_TOKEN="\${LITELLM_KEY}" \\
  ANTHROPIC_BASE_URL="\${LITELLM_URL}" \\
  ANTHROPIC_API_KEY="\${LITELLM_KEY}" \\
  claude --model qwen3-coder-next'

# 추론 모델 — cyber2 QwQ-32B (추론/설계)
alias claude-reason='ANTHROPIC_AUTH_TOKEN=ollama \\
  ANTHROPIC_BASE_URL="http://${REASONING_SERVER}:${OLLAMA_PORT}" \\
  ANTHROPIC_API_KEY="" \\
  claude --model qwq:32b'

# <<< vibe-lab 설정 <<<
ALIASES

ok "alias 추가됨: claude-cloud, claude-local, claude-reason"

# ── Step 5: Claude Code settings.json ──
info "Claude Code settings.json 설정 중..."

mkdir -p "$HOME/.claude"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    ok "기존 settings.json 백업됨"
fi

cat > "$SETTINGS_FILE" << 'SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(wc:*)",
      "Bash(git:*)",
      "Read(*)",
      "Glob(*)",
      "Grep(*)"
    ],
    "deny": []
  }
}
SETTINGS

ok "settings.json 설정됨"

# ── Step 6: 에이전트 배포 ──
info "vibe-lab 에이전트 배포 중..."

AGENTS_DIR="$HOME/.claude/agents"
mkdir -p "$AGENTS_DIR"

if [ -d "$AGENTS_SRC" ]; then
    cp "$AGENTS_SRC"/*.md "$AGENTS_DIR/" 2>/dev/null || true
    agent_count=$(ls "$AGENTS_DIR"/*.md 2>/dev/null | wc -l)
    ok "${agent_count}개 에이전트 배포됨"
    for f in "$AGENTS_DIR"/*.md; do
        name=$(grep -oP '^name:\s*\K.*' "$f" 2>/dev/null || basename "$f" .md)
        model=$(grep -oP '^model:\s*\K.*' "$f" 2>/dev/null || echo "default")
        echo "    - ${name} (model: ${model})"
    done
else
    warn "에이전트 디렉토리 없음: $AGENTS_SRC"
fi

# ── Step 7: 슬래시 커맨드 배포 ──
info "슬래시 커맨드 배포 중..."

COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"

if [ -d "$COMMANDS_SRC" ]; then
    cp "$COMMANDS_SRC"/*.md "$COMMANDS_DIR/" 2>/dev/null || true
    cmd_count=$(ls "$COMMANDS_DIR"/*.md 2>/dev/null | wc -l)
    ok "${cmd_count}개 커맨드 배포됨 (/debug, /unit-test)"
else
    warn "커맨드 디렉토리 없음: $COMMANDS_SRC"
fi

# ── Step 9: MCP 서버 설치 ──
info "MCP 서버 설치 중..."

MCP_SERVER="${SCRIPT_DIR}/mcp/server.py"
MCP_VENV="$HOME/.vibe-lab-mcp"
MCP_PYTHON=""

if [ ! -f "$MCP_SERVER" ]; then
    warn "  MCP 서버 파일 없음: $MCP_SERVER — 건너뜀"
else
    # Python 3.10+ 탐색 (시스템)
    for py in python3.12 python3.11 python3.10; do
        if command -v "$py" &>/dev/null; then
            ver=$("$py" -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null)
            if [ "$ver" = "True" ]; then
                MCP_PYTHON="$py"
                break
            fi
        fi
    done

    # 시스템에 없으면 conda로 환경 생성
    if [ -z "$MCP_PYTHON" ]; then
        if command -v conda &>/dev/null; then
            info "  Python 3.10+ 없음 — conda 환경 생성 중..."
            conda create -n mcp-vibe python=3.10 -y -q 2>/dev/null
            MCP_PYTHON=$(conda run -n mcp-vibe which python 2>/dev/null)
            MCP_VENV=""   # conda env 사용 시 별도 venv 불필요
        else
            warn "  Python 3.10+ 및 conda 없음 — MCP 서버 건너뜀"
            MCP_SERVER=""
        fi
    fi

    if [ -n "$MCP_SERVER" ] && [ -n "$MCP_PYTHON" ]; then
        # venv 생성 (conda 사용 시 스킵)
        if [ -n "$MCP_VENV" ] && [ ! -d "$MCP_VENV" ]; then
            info "  가상환경 생성 중: $MCP_VENV"
            "$MCP_PYTHON" -m venv "$MCP_VENV"
            MCP_PYTHON="$MCP_VENV/bin/python"
        elif [ -n "$MCP_VENV" ] && [ -d "$MCP_VENV" ]; then
            MCP_PYTHON="$MCP_VENV/bin/python"
        fi

        # 패키지 설치
        info "  mcp, httpx 패키지 설치 중..."
        "$MCP_PYTHON" -m pip install mcp httpx -q 2>/dev/null
        ok "  패키지 설치 완료"

        # MCP 서버 등록
        if claude mcp list 2>/dev/null | grep -q "vibe-lab"; then
            info "  vibe-lab MCP 이미 등록됨 — 경로 갱신"
            claude mcp remove vibe-lab 2>/dev/null
        fi
        claude mcp add vibe-lab "$MCP_PYTHON" "$MCP_SERVER" --scope user 2>/dev/null
        ok "  vibe-lab MCP 등록 완료 ($MCP_PYTHON)"
    fi
fi

# ── Step 10: 연결 테스트 ──
echo ""
info "연결 테스트 중..."

response=$(curl -sf --connect-timeout 15 \
    "http://${LITELLM_SERVER}:4000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer vibe-lab" \
    -d "{
        \"model\": \"qwen3-coder-next\",
        \"max_tokens\": 64,
        \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}]
    }" 2>/dev/null || echo "")

if [ -n "$response" ]; then
    reply=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'][:60])
except: print('(파싱 실패)')
" 2>/dev/null || echo "(파싱 실패)")
    ok "LiteLLM 응답: $reply"
else
    warn "LiteLLM (${LITELLM_SERVER}:4000) 연결 실패 — 서버 관리자에게 문의하세요."
fi

# ── 완료 ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  ${GREEN}설정 완료!${NC}"
echo ""
echo "  새 터미널을 열거나:"
echo -e "    ${CYAN}source ${SHELL_RC}${NC}"
echo ""
echo "  사용법:"
echo -e "    ${CYAN}claude-local${NC}    Qwen3-Coder-Next 80B LB (8asus GPU 0-2 / 3-5, 최대 2명 동시, ~66 t/s)"
echo -e "    ${CYAN}claude-reason${NC}  cyber2 QwQ-32B (추론/설계)"
if [ "$ANTHROPIC_API_KEY" != "skip" ]; then
echo -e "    ${CYAN}claude-cloud${NC}    유료 Claude (Opus/Sonnet)"
fi
echo ""
echo "  에이전트: claude-local 실행 후 /agents"
echo "  MCP 도구: claude-local 실행 후 /mcp"
echo "═══════════════════════════════════════════════════════"
echo ""

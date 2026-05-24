#!/usr/bin/env bash
# =============================================================================
# vibe-lab-cleanup.sh — 기존 vLLM/LiteLLM/OpenHands 인프라 제거
#
# CyberSecurity-1G에서 실행
# 모든 서버의 기존 Docker 컨테이너를 정리합니다.
#
# 사용법:
#   chmod +x vibe-lab-cleanup.sh
#   ./vibe-lab-cleanup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

SSH="ssh -p 8510 -o ConnectTimeout=5 -o BatchMode=yes"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  vibe-lab 기존 인프라 정리"
echo "  vLLM, LiteLLM, OpenHands, Aider 제거"
echo "═══════════════════════════════════════════════════════"
echo ""

echo -e "${YELLOW}주의: 이 스크립트는 다음을 제거합니다:${NC}"
echo "  - CyberSecurity-1G: vibe-litellm, vibe-redis, vibe-openhands, vibe-nginx"
echo "  - 8asus: vibe-coder-8asus-* 컨테이너"
echo "  - 4gpu: vibe-coder-4gpu, vibe-fast-4gpu 컨테이너"
echo "  - 8gpu: vibe 관련 vLLM 컨테이너"
echo "  - cyber2: vLLM 컨테이너"
echo ""
read -rp "계속하시겠습니까? (yes를 입력): " confirm
if [ "$confirm" != "yes" ]; then
    echo "중단합니다."
    exit 0
fi

# ── CyberSecurity-1G (로컬) ──
echo ""
info "CyberSecurity-1G 정리 중..."

for container in vibe-litellm vibe-redis vibe-openhands vibe-nginx; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        docker stop "$container" 2>/dev/null && docker rm "$container" 2>/dev/null
        ok "  제거됨: $container"
    fi
done

# OpenHands agent 컨테이너들
oh_count=$(docker ps -a --filter name=oh-agent -q | wc -l)
if [ "$oh_count" -gt 0 ]; then
    docker ps -a --filter name=oh-agent -q | xargs docker rm -f 2>/dev/null
    ok "  OpenHands 에이전트 ${oh_count}개 제거됨"
fi

# ── 8asus ──
info "8asus 정리 중..."
$SSH 8asus "docker ps -a --filter name=vibe --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done" 2>/dev/null || warn "8asus 연결 실패"

# ── CyberSecurity-2G ──
info "CyberSecurity-2G 정리 중..."
$SSH CyberSecurity-2G "docker ps -a --filter name=vibe --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done; \
docker ps -a --filter name=vllm --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done" 2>/dev/null || warn "CyberSecurity-2G 연결 실패"

# ── 4gpu ──
info "4gpu 정리 중..."
$SSH 4gpu "docker ps -a --filter name=vibe --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done" 2>/dev/null || warn "4gpu 연결 실패"

# ── 8gpu ──
info "8gpu 정리 중..."
$SSH 8gpu "docker ps -a --filter name=vibe --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done; \
docker ps -a --filter name=vllm --format '{{.Names}}' | while read c; do docker stop \$c && docker rm \$c && echo \"  제거됨: \$c\"; done" 2>/dev/null || warn "8gpu 연결 실패"

# ── 확인 ──
echo ""
info "남은 컨테이너 확인..."
echo "  [CyberSecurity-1G]"
docker ps --format '  {{.Names}}\t{{.Image}}' 2>/dev/null || echo "  (없음)"

for server in 8asus CyberSecurity-2G 4gpu 8gpu; do
    echo "  [$server]"
    $SSH "$server" "docker ps --format '  {{.Names}}\t{{.Image}}'" 2>/dev/null || echo "  (연결 실패)"
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  ${GREEN}정리 완료!${NC}"
echo "  다음 단계: ./vibe-lab-setup.sh 실행 (Ollama 설치)"
echo "═══════════════════════════════════════════════════════"
echo ""

#!/usr/bin/env bash
# =============================================================================
# vibe-lab-check.sh — Ollama 클러스터 상태 점검
# CyberSecurity-1G에서 실행
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SSH="ssh -p 8510 -o ConnectTimeout=3 -o BatchMode=yes"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  vibe-lab 클러스터 상태 점검 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

# ── Ollama 인스턴스 ──
echo ""
echo -e "${BLUE}[Ollama 인스턴스]${NC}"

# 형식: "서버|포트|모델|설명"
declare -a SERVERS=(
    "8asus|11434|qwen3-coder-next|주력 코딩 (단독)"
    "CyberSecurity-2G|11434|qwq:32b|추론/설계"
    "4gpu|11434|qwen3-coder:30b|코딩 LB (GPU 0-1)"
    "4gpu|11435|qwen3-coder:30b|코딩 LB (GPU 2-3)"
    "8gpu|11434|qwen3-coder:30b|코딩 LB (GPU 0-1)"
    "8gpu|11435|qwen3-coder:30b|코딩 LB (GPU 2-3)"
    "8gpu|11436|qwen3-coder:30b|코딩 LB (GPU 4-5)"
    "8gpu|11437|qwen3-coder:30b|코딩 LB (GPU 6-7)"
)

healthy=0
total=${#SERVERS[@]}

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r server port model role <<< "$entry"

    tags=$(curl -sf --connect-timeout 3 "http://${server}:${port}/api/tags" 2>/dev/null || echo "")
    if [ -n "$tags" ]; then
        loaded=$(echo "$tags" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    names = [m['name'] for m in d.get('models', [])]
    print(', '.join(names) if names else '(모델 없음)')
except: print('(파싱 실패)')
" 2>/dev/null || echo "확인 불가")
        echo -e "  ${GREEN}●${NC} ${server}:${port} — ${role} [${loaded}]"
        ((healthy++))
    else
        echo -e "  ${RED}●${NC} ${server}:${port} — ${role} — ${RED}연결 실패${NC}"
    fi
done

echo ""
echo "  정상: ${healthy}/${total}"

# ── Tool Calling 테스트 ──
echo ""
echo -e "${BLUE}[Tool Calling 테스트]${NC}"

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r server port model role <<< "$entry"

    response=$(curl -sf --connect-timeout 15 "http://${server}:${port}/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ollama" \
        -H "anthropic-version: 2023-06-01" \
        -d "{
            \"model\": \"${model}\",
            \"max_tokens\": 256,
            \"tools\": [{
                \"name\": \"test_tool\",
                \"description\": \"A test tool\",
                \"input_schema\": {
                    \"type\": \"object\",
                    \"properties\": {\"input\": {\"type\": \"string\"}},
                    \"required\": [\"input\"]
                }
            }],
            \"messages\": [{\"role\": \"user\", \"content\": \"Use the test_tool with input hello\"}]
        }" 2>/dev/null || echo "")

    if echo "$response" | grep -q "tool_use"; then
        echo -e "  ${GREEN}●${NC} ${server}:${port} (${model}) — tool calling 정상"
    elif [ -z "$response" ]; then
        echo -e "  ${RED}●${NC} ${server}:${port} (${model}) — 응답 없음"
    else
        echo -e "  ${YELLOW}●${NC} ${server}:${port} (${model}) — 응답 있으나 tool_use 미확인"
    fi
done

# ── GPU 상태 ──
echo ""
echo -e "${BLUE}[GPU 사용 현황]${NC}"

for server in 8asus CyberSecurity-2G 4gpu 8gpu; do
    gpu_info=$($SSH "$server" \
        "nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits" \
        2>/dev/null)
    if [ -n "$gpu_info" ]; then
        echo -e "  ${YELLOW}${server}${NC}"
        while IFS=',' read -r idx mem_used mem_total util temp; do
            idx=$(echo "$idx" | tr -d ' ')
            mem_used=$(echo "$mem_used" | tr -d ' ')
            mem_total=$(echo "$mem_total" | tr -d ' ')
            util=$(echo "$util" | tr -d ' ')
            temp=$(echo "$temp" | tr -d ' ')
            [ -z "$mem_total" ] || [ "$mem_total" -eq 0 ] 2>/dev/null && continue
            pct=$((mem_used * 100 / mem_total))
            if [ "$pct" -gt 90 ]; then color=$RED
            elif [ "$pct" -gt 70 ]; then color=$YELLOW
            else color=$GREEN; fi
            printf "    GPU %s: ${color}%5s/%5s MiB (%2d%%)${NC}  util: %3s%%  temp: %s°C\n" \
                "$idx" "$mem_used" "$mem_total" "$pct" "$util" "$temp"
        done <<< "$gpu_info"
    else
        echo -e "  ${YELLOW}${server}${NC}: ${RED}SSH 연결 실패${NC}"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo ""

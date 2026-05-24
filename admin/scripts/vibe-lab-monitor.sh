#!/usr/bin/env bash
# =============================================================================
# vibe-lab-monitor.sh — 클러스터 실시간 모니터링
# 사용법: ./vibe-lab-monitor.sh [갱신주기(초, 기본 3)]
# =============================================================================

INTERVAL="${1:-3}"
SSH="ssh -p 8510 -o ConnectTimeout=2 -o BatchMode=yes"

declare -a SERVERS=("8asus" "CyberSecurity-2G")
declare -A ROLES=(
    ["8asus"]="코딩LB(×3, GPU0-5 full)"
    ["CyberSecurity-2G"]="추론"
)
# 서버별 활성 포트 목록 (공백 구분)
declare -A PORTS=(
    ["8asus"]="11434 11435 11436"
    ["CyberSecurity-2G"]="11434"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

bar() {
    local pct=$1 width=20
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color=$GREEN
    [ "$pct" -gt 70 ] && color=$YELLOW
    [ "$pct" -gt 90 ] && color=$RED
    printf "${color}["
    printf '%0.s█' $(seq 1 $filled 2>/dev/null) 2>/dev/null || printf '%*s' "$filled" | tr ' ' '█'
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "]${NC} %3d%%" "$pct"
}

fetch_gpu() {
    local server=$1
    $SSH "$server" \
        "nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu,temperature.gpu,name \
         --format=csv,noheader,nounits 2>/dev/null" 2>/dev/null
}

fetch_ollama_ps() {
    local server=$1
    local ports="${PORTS[$server]}"
    local any=false
    for port in $ports; do
        result=$(curl -sf --connect-timeout 2 "http://${server}:${port}/api/ps" 2>/dev/null | \
            python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    for m in models:
        name = m.get('name','?')
        vram = m.get('size_vram', 0) // (1024**3)
        ctx  = m.get('context_length', 0)
        print(f'  ▶ :{port}  {name}  VRAM:{vram}GB  ctx:{ctx:,}')
except:
    pass
" port="$port" 2>/dev/null)
        [ -n "$result" ] && { echo "$result"; any=true; }
    done
    [ "$any" = false ] && echo "  (대기 중)"
}

while true; do
    clear
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}  vibe-lab 클러스터 모니터  ${NC}  갱신: ${INTERVAL}s  ${CYAN}%s${NC}\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"

    for server in "${SERVERS[@]}"; do
        role="${ROLES[$server]}"
        echo ""
        echo -e "  ${BOLD}${YELLOW}${server}${NC}  (${role})"
        echo -e "  ${BLUE}────────────────────────────────────────────────${NC}"

        gpu_data=$(fetch_gpu "$server")
        if [ -z "$gpu_data" ]; then
            echo -e "  ${RED}● SSH 연결 실패${NC}"
            continue
        fi

        total_used=0; total_total=0
        while IFS=',' read -r idx mem_used mem_total util temp name; do
            idx=$(echo "$idx" | tr -d ' ')
            mem_used=$(echo "$mem_used" | tr -d ' ')
            mem_total=$(echo "$mem_total" | tr -d ' ')
            util=$(echo "$util" | tr -d ' ')
            temp=$(echo "$temp" | tr -d ' ')
            name=$(echo "$name" | xargs)
            [ -z "$mem_total" ] || [ "$mem_total" -eq 0 ] 2>/dev/null && continue
            mem_pct=$(( mem_used * 100 / mem_total ))
            total_used=$(( total_used + mem_used ))
            total_total=$(( total_total + mem_total ))
            printf "  GPU%-2s %-22s  VRAM: " "$idx" "$name"
            bar "$mem_pct"
            printf "  %5s/%5sMiB  util:%3s%%  %s°C\n" \
                "$mem_used" "$mem_total" "$util" "$temp"
        done <<< "$gpu_data"

        if [ "$total_total" -gt 0 ]; then
            total_pct=$(( total_used * 100 / total_total ))
            total_used_gb=$(( total_used / 1024 ))
            total_total_gb=$(( total_total / 1024 ))
            printf "  ${BOLD}합계%-20s  VRAM: ${NC}" ""
            bar "$total_pct"
            printf "  ${BOLD}%4dGB/%4dGB${NC}\n" "$total_used_gb" "$total_total_gb"
        fi

        echo -e "  ${CYAN}로드된 모델:${NC}"
        fetch_ollama_ps "$server"
    done

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Ctrl+C 로 종료  │  인자로 갱신 주기 변경: ${CYAN}./vibe-lab-monitor.sh 5${NC}"

    sleep "$INTERVAL"
done

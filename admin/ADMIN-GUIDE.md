# vibe-lab 관리자 운영 매뉴얼

Ollama 기반 분산 LLM 추론 클러스터의 설치, 운영, 장애 대응 문서입니다.

---

## 1. 아키텍처

### 전체 구성

```
사용자 워크스테이션
┌────────────────────────────────────────────────────────────────┐
│  Claude Code                                                   │
│    │                                                           │
│    ├─ claude-local  → LiteLLM :4000 → 8asus:11434/11435/11436 │
│    ├─ claude-reason → CyberSecurity-2G:11434 (qwq:32b)        │
│    └─ claude-cloud  → Anthropic API (유료)                     │
│                                                                │
│    MCP Server (stdio)                                          │
│      ├─ reason          → CyberSecurity-2G:11434 (qwq:32b)    │
│      ├─ code            → 8asus:11434 (qwen3-coder-next)       │
│      └─ reason_then_code (파이프라인)                           │
└────────────────────────────────────────────────────────────────┘
```

### 서버별 배치

| 서버 | GPU | VRAM | 모델 | 역할 |
|------|-----|------|------|------|
| 8asus | RTX A5000 ×8 | 192GB | qwen3-coder-next | 코딩 LB (GPU 0-5, pair 3개) |
| CyberSecurity-2G | Quadro RTX 8000 ×2 | 96GB | qwq:32b | 추론/설계 |

SSH 포트: 8510 (모든 서버 공통)  
GPU 6-7 (8asus): DL 연구용 예약 — 평상시 Ollama 미실행

### 8asus 멀티 인스턴스 구성

GPU 2장씩 묶어 qwen3-coder-next(~48GB)를 full GPU 모드로 실행합니다.

```
GPU 0-1: ollama-pair@0  (포트 11434)  qwen3-coder-next ─┐
GPU 2-3: ollama-pair@1  (포트 11435)  qwen3-coder-next  ├→ LiteLLM round-robin
GPU 4-5: ollama-pair@2  (포트 11436)  qwen3-coder-next ─┘
GPU 6-7: (DL 연구 예약)
```

### 파일 구조

```
~/vibe-lab-admin/
├── ADMIN-GUIDE.md
├── litellm/
│   └── config.yaml          ← LiteLLM 로드밸런서 설정
├── mcp-server/
│   ├── server.py             ← 관리자용 MCP 서버
│   └── requirements.txt
└── scripts/
    ├── vibe-lab-setup.sh     ← 클러스터 초기 설치
    ├── vibe-lab-check.sh     ← 상태 점검
    ├── vibe-lab-monitor.sh   ← 실시간 모니터링
    └── vibe-lab-cleanup.sh   ← 구 Docker 인프라 정리

~/vibe-lab-user/              ← 사용자 배포 디렉토리
├── README.md
├── vibe-lab-init.sh
├── mcp/
│   └── server.py
└── agents/
```

---

## 2. 초기 설치

### 2.1 사전 조건

```bash
# SSH 키 설정 (1회)
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 2>/dev/null || true
for server in 8asus CyberSecurity-2G; do
    ssh-copy-id -p 8510 "$server"
done
```

SSH config (`~/.ssh/config`):
```
Host 8asus CyberSecurity-2G
    Port 8510
    StrictHostKeyChecking no
```

### 2.2 Ollama 설치 및 모델 배포

```bash
cd ~/vibe-lab-admin/scripts/
chmod +x *.sh
./vibe-lab-setup.sh
```

### 2.3 8asus GPU 페어 멀티 인스턴스 설정

`vibe-lab-setup.sh`가 자동으로 처리합니다. 수동 설정이 필요한 경우:

```bash
# 기존 단일 서비스 비활성화
ssh 8asus "sudo systemctl stop ollama && sudo systemctl disable ollama"

# GPU 페어 template 서비스 생성
ssh -p 8510 8asus "sudo tee /etc/systemd/system/ollama-pair@.service > /dev/null" << 'EOF'
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
EOF

# 인스턴스 0-2 등록 및 시작 (GPU 0-5, pair@0/1/2)
ssh 8asus "sudo systemctl daemon-reload"
for i in 0 1 2; do
    ssh 8asus "sudo systemctl enable ollama-pair@$i && sudo systemctl start ollama-pair@$i"
done
```

### 2.4 LiteLLM 로드밸런서 설치

```bash
# conda 환경 생성
conda create -n litellm-vibe python=3.10 -y
conda run -n litellm-vibe pip install 'litellm[proxy]'
```

systemd 서비스 등록:
```bash
sudo tee /etc/systemd/system/litellm-vibe.service > /dev/null << 'EOF'
[Unit]
Description=vibe-lab LiteLLM Load Balancer
After=network.target

[Service]
Type=simple
User=tjpark
WorkingDirectory=/home/tjpark/vibe-lab-admin/litellm
ExecStart=/home/tjpark/.conda/envs/litellm-vibe/bin/litellm \
  --config /home/tjpark/vibe-lab-admin/litellm/config.yaml \
  --port 4000 --host 0.0.0.0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable litellm-vibe
sudo systemctl start litellm-vibe
```

### 2.5 MCP 서버 설치

```bash
# conda 환경 생성 (Python 3.10+ 필요)
conda create -n mcp-vibe python=3.10 -y
conda run -n mcp-vibe pip install mcp httpx

# Claude Code MCP 등록 (user 범위)
claude mcp add vibe-lab \
  /home/tjpark/.conda/envs/mcp-vibe/bin/python \
  /home/tjpark/vibe-lab-admin/mcp-server/server.py \
  --scope user
```

---

## 3. 일상 운영

### 3.1 전체 상태 확인

```bash
~/vibe-lab-admin/scripts/vibe-lab-check.sh
```

### 3.2 실시간 모니터링

```bash
~/vibe-lab-admin/scripts/vibe-lab-monitor.sh        # 3초 갱신
~/vibe-lab-admin/scripts/vibe-lab-monitor.sh 5      # 5초 갱신
```

### 3.3 LiteLLM 상태

```bash
# 등록된 모델 확인
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer vibe-lab" | python3 -m json.tool

# 서비스 재시작
sudo systemctl restart litellm-vibe
```

### 3.4 8asus 인스턴스 관리

```bash
# 전체 상태
for i in 0 1 2; do
    PORT=$((11434 + i))
    STATUS=$(curl -sf http://8asus:$PORT/api/tags 2>/dev/null && echo OK || echo FAIL)
    echo "pair@$i (GPU $((i*2))-$((i*2+1))) :$PORT $STATUS"
done

# 특정 인스턴스 재시작
ssh 8asus "sudo systemctl restart ollama-pair@1"

# 로그 확인
ssh 8asus "journalctl -u 'ollama-pair@*' --no-pager -n 20"
```

### 3.5 DL 연구용 GPU 반납/복구

GPU 6-7은 평상시 Ollama를 실행하지 않습니다. DL 연구가 끝나면 추가 용량이 필요할 경우 pair@3을 시작할 수 있습니다.

```bash
# pair@3 추가 시작 (GPU 6-7, 포트 11437) — LiteLLM config.yaml에도 추가 필요
ssh 8asus "sudo systemctl enable ollama-pair@3 && sudo systemctl start ollama-pair@3"

# 연구 용도로 중단
ssh 8asus "sudo systemctl stop ollama-pair@3 && sudo systemctl disable ollama-pair@3"
```

---

## 4. 모델 관리

### 4.1 모델 추가/교체

```bash
ssh 8asus "ollama pull <새모델>"
ssh 8asus "ollama rm <기존모델>"
```

template 서비스와 LiteLLM `config.yaml`의 모델명도 함께 수정합니다.

### 4.2 양자화 권장

Q5_K_M 이상 권장 (Q3 이하는 tool calling 불안정)

---

## 5. MCP 서버

### 5.1 도구 목록

| 도구 | 실행 서버 | 타임아웃 |
|------|---------|---------|
| `reason` | CyberSecurity-2G / qwq:32b | 600s |
| `code` | 8asus / qwen3-coder-next | 300s |
| `reason_then_code` | 파이프라인 (reason → code) | 900s |

### 5.2 슬래시 커맨드

```
~/.claude/commands/debug.md      → /debug
~/.claude/commands/unit-test.md  → /unit-test
```

---

## 6. 장애 대응

### 6.1 진단 플로우

```
alias 에러
  → curl http://<서버>:11434/api/tags 확인
  → vibe-lab-check.sh 실행
  → journalctl -u 'ollama-pair@*' 확인

LiteLLM 에러
  → sudo systemctl status litellm-vibe
  → curl http://localhost:4000/health -H "Authorization: Bearer vibe-lab"

MCP 에러
  → claude mcp list 에서 vibe-lab 상태 확인
  → conda run -n mcp-vibe python ~/vibe-lab-admin/mcp-server/server.py 수동 실행
```

### 6.2 8asus 인스턴스 장애

```bash
# 특정 포트 응답 없을 때
ssh 8asus "sudo systemctl restart ollama-pair@<N>"

# VRAM 과점유 시 강제 정리
ssh 8asus "sudo kill -9 \$(lsof /dev/nvidia<N> | awk 'NR>1{print \$2}' | sort -u)"
```

### 6.3 cyber2 NVML 오류

`Failed to initialize NVML: Driver/library version mismatch` 메시지가 나오면 드라이버 업데이트 후 재부팅이 필요합니다.

```bash
ssh CyberSecurity-2G "sudo reboot"
```

---

## 7. 사용자 온보딩

```bash
# 사용자에게 vibe-lab-user 디렉토리 배포 후
./vibe-lab-init.sh
```

init.sh 자동 처리 항목:
- Claude Code 설치 확인
- Ollama 서버 연결 확인 (8asus, CyberSecurity-2G)
- shell alias 등록 (claude-local, claude-reason, claude-cloud)
- `~/.claude/settings.json` 생성
- MCP 서버 환경 구성 및 등록
- `~/.claude/agents/` 에이전트 배포

---

## 8. 빠른 명령 참조

| 작업 | 명령 |
|------|------|
| 전체 상태 | `~/vibe-lab-admin/scripts/vibe-lab-check.sh` |
| 실시간 모니터 | `~/vibe-lab-admin/scripts/vibe-lab-monitor.sh` |
| LiteLLM 모델 목록 | `curl -s http://localhost:4000/v1/models -H "Authorization: Bearer vibe-lab"` |
| 8asus 인스턴스 상태 | `for i in 0 1 2; do curl -sf http://8asus:$((11434+i))/api/tags >/dev/null && echo "pair@$i OK"; done` |
| DL GPU 추가 | `ssh 8asus "sudo systemctl start ollama-pair@3"` |
| DL GPU 반납 | `ssh 8asus "sudo systemctl stop ollama-pair@3"` |
| MCP 상태 | `claude mcp list` |
| LiteLLM 재시작 | `sudo systemctl restart litellm-vibe` |

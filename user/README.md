# vibe-lab 사용자 매뉴얼

Ollama 기반 GPU 클러스터에서 로컬 LLM을 Claude Code로 사용하는 환경입니다.

---

## 설치

서버 설정은 관리자가 완료된 상태여야 합니다.

### Linux / macOS

```bash
cd vibe-lab-user/
chmod +x vibe-lab-init.sh
./vibe-lab-init.sh          # sudo 없이 실행
```

완료 후:
```bash
source ~/.zshrc    # 또는 source ~/.bashrc
```

### Windows (WSL2)

Claude Code는 Windows에서 WSL2 환경이 필요합니다.

**1단계: WSL2 설치** (최초 1회, PowerShell 관리자 권한)

```powershell
wsl --install
```

설치 후 재시작하면 Ubuntu가 자동 실행됩니다.

**2단계: WSL Ubuntu 안에서 동일하게 실행**

```bash
cd vibe-lab-user/
chmod +x vibe-lab-init.sh
./vibe-lab-init.sh
source ~/.bashrc
```

**VS Code 연동 (권장)**

```bash
# WSL 터미널에서
code .
```

VS Code Remote-WSL 확장이 자동 설치되며, 이후 VS Code에서 Claude Code를 바로 사용할 수 있습니다.

> **참고:** Ollama 서버는 내부 네트워크의 Linux 서버에 있으므로 Windows/WSL 환경에서도 동일하게 접속됩니다.

---

## 진입 명령 (alias)

### LiteLLM 로드밸런서 경유 (기본)

```bash
claude-local      # 4gpu + 8gpu — Qwen3-Coder 30B 로드밸런싱 (다중 사용자)
claude-reason-lb  # 8asus GPU ×8 — QwQ-32B 로드밸런싱   (최대 8명 동시)
claude-v2-reason  # 4gpu vLLM    — QwQ-32B on-demand
```

### Ollama 직접 연결

```bash
claude-next       # 8asus   — Qwen3-Coder-Next 80B MoE (고품질, 단독)
claude-reason     # cyber2  — QwQ-32B                  (추론/설계, 단일)
claude-fast       # 4gpu    — Qwen3-Coder 30B           (직접 연결)
claude-8gpu       # 8gpu    — Qwen3-Coder 30B           (직접 연결)
claude-cloud      # Anthropic API — 유료 Claude          (최고 품질)
```

### 언제 어떤 alias를 쓸까

| 상황 | 추천 |
|------|------|
| 일반 코딩 (다중 사용자) | `claude-local` |
| 아키텍처 설계, 복잡한 추론 | `claude-reason-lb` |
| 고품질 코딩 (혼자 쓸 때) | `claude-next` |
| 여러 명이 동시에 추론 | `claude-reason-lb` (8명 동시 가능) |
| 최고 품질 필요 | `claude-cloud` |

---

## MCP 도구

어떤 alias로 진입하든 Claude Code 세션에서 동일하게 사용할 수 있습니다.
`/mcp` 명령으로 연결 상태를 확인하세요.

### vibe-lab 도구 (GPU 클러스터 오케스트레이션)

| 도구 | 실행 서버 | 모델 | 용도 |
|------|----------|------|------|
| `reason` | CyberSecurity-2G | qwq:32b | 설계, 아키텍처, 문제 분석 |
| `code` | 8asus | qwen3-coder-next | 코드 구현 |
| `reason_then_code` | cyber2 → 8asus | 파이프라인 | 자동 설계 후 구현 |
| `fast_code` | 4gpu | qwen3-coder:30b | 빠른 코드 생성 |

```
# 명시적 분리 (설계 검토 후 구현)
"reason 도구로 이 설계의 트레이드오프를 분석해줘"
"분석 결과를 바탕으로 code 도구로 구현해줘"

# 자동 파이프라인
"reason_then_code로 파일 캐시 모듈 만들어줘"
```

### Google Drive 도구 (✔ 연결됨)

| 도구 | 기능 |
|------|------|
| `search_files` | 파일 검색 |
| `list_recent_files` | 최근 파일 목록 |
| `read_file_content` | 파일 내용 읽기 |
| `get_file_metadata` | 메타데이터 조회 |
| `get_file_permissions` | 권한 조회 |
| `create_file` | 파일 생성 |
| `download_file_content` | 파일 다운로드 |

### Gmail / Google Calendar (△ 인증 필요)

처음 사용 시 세션에서 인증 링크가 안내됩니다.

---

## 슬래시 커맨드

| 커맨드 | 동작 |
|--------|------|
| `/debug` | `reason` → `fast_code` 순으로 버그 분석·수정 |
| `/unit-test` | `reason` → `fast_code` 순으로 테스트 설계·작성 |

```
/debug
<에러 메시지나 코드 붙여넣기>

/unit-test
<테스트할 코드 붙여넣기>
```

---

## 에이전트

`/agents` 또는 `@에이전트명`으로 호출합니다.

| 에이전트 | 역할 |
|---------|------|
| `architect` | 시스템 설계, 리팩토링 계획 |
| `coder` | 코드 작성, 기능 구현 |
| `reviewer` | 코드 리뷰 (읽기 전용) |
| `debugger` | 버그 진단, 원인 분석 |
| `tester` | 테스트 코드 작성 |

---

## 문제 해결

### 첫 응답이 느림

Ollama는 첫 요청 시 모델을 GPU에 로드합니다. 32B 모델은 30초~1분 소요됩니다.

### 연결 실패

```bash
curl http://8asus:11434/api/tags
curl http://CyberSecurity-2G:11434/api/tags
curl http://4gpu:11434/api/tags
```

### MCP 도구가 안 보임

```
/mcp
```
`vibe-lab ✔ connected` 가 없으면 관리자에게 문의하세요.

### alias가 없음

```bash
grep "vibe-lab" ~/.zshrc
source ~/.zshrc
```

없으면 `vibe-lab-init.sh`를 다시 실행하세요.

---

## 파일 구조

```
vibe-lab-user/
├── README.md               ← 이 문서
├── vibe-lab-init.sh        ← 워크스테이션 설정 스크립트
├── mcp/
│   └── server.py           ← vibe-lab MCP 서버
└── agents/
    ├── architect.md
    ├── coder.md
    ├── reviewer.md
    ├── debugger.md
    └── tester.md

~/.claude/                  ← init.sh가 자동 생성
├── settings.json
├── agents/
└── commands/
    ├── debug.md            ← /debug
    └── unit-test.md        ← /unit-test
```

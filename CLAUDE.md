# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is the **vibe-lab** release package — a deployment kit for running Claude Code against a local Ollama-based GPU cluster instead of (or alongside) the Anthropic API. It contains two directories:

- `user/` — distributed to end users; sets up their workstation
- `admin/` — cluster operations for the administrator running the GPU servers

## Architecture

```
User Workstation (Claude Code)
  ├─ claude-local    → LiteLLM :4000  qwen2.5-coder-32b LB  (8asus GPU 3-5, 1GPU/instance, max 3 users, ~30 t/s)
  ├─ claude-highend  → LiteLLM :4000  qwen3-coder-next 80B  (8asus GPU 0-1-2, single instance, ~66 t/s)
  ├─ claude-reason   → cyber2:11434   qwq:32b               (reasoning/design)
  └─ claude-cloud    → Anthropic API  paid Claude            (highest quality)

MCP Server (stdio, runs on user's machine)
  ├─ reason          → CyberSecurity-2G / qwq:32b   (600s timeout)
  ├─ code            → 8asus / qwen3-coder-next      (300s timeout)
  └─ reason_then_code → pipelines reason → code automatically
```

Claude Code connects to Ollama via `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN=ollama`. LiteLLM (port 4000) load-balances across the 8 per-GPU Ollama instances on 8asus (ports 11434–11441).

## Key Files

| File | Purpose |
|------|---------|
| `user/vibe-lab-init.sh` | One-shot user setup: installs Claude Code, writes shell aliases, creates `~/.claude/settings.json`, deploys agents, registers the MCP server |
| `user/mcp/server.py` | FastMCP server exposing `reason`, `code`, `reason_then_code` tools |
| `user/agents/*.md` | Sub-agent definitions deployed to `~/.claude/agents/` |
| `admin/litellm/config.yaml` | LiteLLM router — round-robin across 8asus GPU instances |
| `admin/mcp-server/server.py` | Admin-side MCP server (same logic, different path) |
| `admin/scripts/vibe-lab-setup.sh` | Cluster bootstrap (Ollama install + model pull on all servers) |
| `admin/scripts/vibe-lab-check.sh` | Health check: Ollama API + tool-calling test + GPU VRAM on all servers |
| `admin/scripts/vibe-lab-monitor.sh` | Continuous monitoring (default 3s refresh) |

## User Setup (run once per workstation)

```bash
cd user/
chmod +x vibe-lab-init.sh
./vibe-lab-init.sh        # no sudo needed
source ~/.zshrc            # or ~/.bashrc
```

The script writes aliases into the shell RC between `# >>> vibe-lab 설정` and `# <<< vibe-lab 설정` markers (idempotent — old block is removed before rewriting).

Server defaults can be overridden before running:
```bash
VIBE_PRIMARY=8asus VIBE_REASONING=CyberSecurity-2G ./vibe-lab-init.sh
```

## Admin Operations

```bash
# Full cluster health check (Ollama + tool-calling + GPU VRAM)
~/vibe-lab-admin/scripts/vibe-lab-check.sh

# Live monitoring (3s refresh)
~/vibe-lab-admin/scripts/vibe-lab-monitor.sh

# Initial cluster bootstrap
~/vibe-lab-admin/scripts/vibe-lab-setup.sh

# LiteLLM service
sudo systemctl restart litellm-vibe
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer vibe-lab" | python3 -m json.tool

# 8asus GPU pair instance management
ssh 8asus "sudo systemctl restart ollama-pair@1"
ssh 8asus "journalctl -u 'ollama-pair@*' --no-pager -n 20"

# Yield GPUs 6-7 to DL research and reclaim
ssh 8asus "sudo systemctl stop ollama-pair@3"
ssh 8asus "sudo systemctl start ollama-pair@3"
```

All SSH connections use port 8510. SSH config must have `Port 8510` for the host aliases.

## MCP Server

`user/mcp/server.py` is a FastMCP (Python `mcp` library) server. It is registered as a `stdio` MCP named `vibe-lab` via:

```bash
claude mcp add vibe-lab <python> <path-to-server.py> --scope user
```

Dependencies: `mcp`, `httpx` (Python 3.10+). The init script creates a venv at `~/.vibe-lab-mcp` or uses a conda env `mcp-vibe`.

The `reason_then_code` tool chains two sequential `httpx` calls — first to the reasoning server, then passes that output as system context to the coding server. No intermediate review step.

## Agent Definitions

Agents in `user/agents/` use YAML frontmatter with `name`, `description`, `model`, and `tools` fields. They are copied to `~/.claude/agents/` by the init script. The `architect` agent uses `model: opus` (routed to whatever `claude` command is active in session).

## Slash Commands

`/debug` and `/unit-test` are installed to `~/.claude/commands/` by the init script. They follow the pattern: call `reason` for analysis/design, then `code` for implementation.

## Choosing the Right Entry Point

| Situation | Use |
|-----------|-----|
| General coding (up to 3 concurrent) | `claude-local` |
| Complex coding, large refactors | `claude-highend` |
| Architecture / complex reasoning | `claude-reason` |
| Highest quality needed | `claude-cloud` |

## Model Quantization Note

Q5_K_M or higher is required for reliable tool calling. Q3 and below are unstable for tool use.

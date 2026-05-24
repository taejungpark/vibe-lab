#!/usr/bin/env python3
"""vibe-lab MCP server — orchestrates reasoning and coding across the GPU cluster."""

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("vibe-lab")

_ENDPOINTS = {
    "reason": "http://CyberSecurity-2G:11434",
    "code":   "http://8asus:11434",
}

_MODELS = {
    "reason": "qwq:32b",
    "code":   "qwen3-coder-next",
}

_TIMEOUTS = {
    "reason": 600,
    "code":   300,
}


async def _chat(role: str, messages: list[dict]) -> str:
    url = f"{_ENDPOINTS[role]}/api/chat"
    payload = {"model": _MODELS[role], "messages": messages, "stream": False}
    async with httpx.AsyncClient(timeout=_TIMEOUTS[role]) as client:
        try:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            return resp.json()["message"]["content"]
        except httpx.ConnectError:
            raise RuntimeError(f"{_ENDPOINTS[role]} 연결 실패 — 서버가 실행 중인지 확인하세요.")
        except httpx.TimeoutException:
            raise RuntimeError(f"{_ENDPOINTS[role]} 타임아웃 ({_TIMEOUTS[role]}s 초과)")


@mcp.tool()
async def reason(prompt: str) -> str:
    """
    CyberSecurity-2G의 qwq:32b로 설계/아키텍처/추론 작업을 수행합니다.
    복잡한 문제 분석, 기술 설계, 트레이드오프 검토에 사용하세요.
    """
    return await _chat("reason", [{"role": "user", "content": prompt}])


@mcp.tool()
async def code(prompt: str, context: str = "") -> str:
    """
    8asus의 qwen3-coder-next로 코드를 구현합니다.
    context에 reason 결과를 넘기면 설계 내용을 반영해 구현합니다.
    """
    messages = []
    if context:
        messages.append({"role": "system", "content": f"설계 컨텍스트:\n{context}"})
    messages.append({"role": "user", "content": prompt})
    return await _chat("code", messages)


@mcp.tool()
async def reason_then_code(prompt: str) -> str:
    """
    자동 파이프라인: qwq:32b로 설계 후 qwen3-coder-next로 구현합니다.
    중간 검토 없이 한 번에 처리합니다. 검토가 필요하면 reason → code를 따로 호출하세요.
    """
    reasoning = await _chat("reason", [{"role": "user", "content": prompt}])
    implementation = await _chat("code", [
        {"role": "system", "content": f"설계 추론:\n{reasoning}"},
        {"role": "user", "content": prompt},
    ])
    return f"## 추론\n\n{reasoning}\n\n## 구현\n\n{implementation}"


if __name__ == "__main__":
    mcp.run()

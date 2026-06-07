from litellm.integrations.custom_logger import CustomLogger
import litellm


class DropThinkingHook(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        import json, time
        # 요청 내용 로깅 (진단용)
        log_entry = {
            "ts": time.time(),
            "call_type": str(call_type),
            "keys": list(data.keys()),
            "model": data.get("model"),
            "num_tools": len(data.get("tools", [])),
            "has_thinking": "thinking" in data,
            "system_len": len(str(data.get("system", ""))),
            "messages_count": len(data.get("messages", [])),
        }
        with open("/tmp/litellm_request_log.jsonl", "a") as f:
            f.write(json.dumps(log_entry) + "\n")

        data.pop("thinking", None)
        data.pop("budget_tokens", None)
        data.pop("context_management", None)
        data.pop("output_config", None)
        if isinstance(data.get("optional_params"), dict):
            data["optional_params"].pop("thinking", None)
            data["optional_params"].pop("budget_tokens", None)
        if isinstance(data.get("extra_body"), dict):
            data["extra_body"].pop("thinking", None)
            data["extra_body"].pop("budget_tokens", None)

        # qwen3-coder-next는 대화가 num_ctx에 가까워지면 출력 생성 중 컨텍스트가
        # 넘쳐 무한 반복(runaway)에 빠짐. Claude Code 기본 출력 상한(128k)을 그대로
        # 두면 폭주가 128k까지 진행되어 세션이 깨짐. 출력 토큰을 안전 상한으로 클램프.
        if data.get("model", "").startswith("qwen3-coder"):
            MAX_OUT = 16384
            if isinstance(data.get("max_tokens"), int) and data["max_tokens"] > MAX_OUT:
                data["max_tokens"] = MAX_OUT

        return data


drop_thinking_hook = DropThinkingHook()

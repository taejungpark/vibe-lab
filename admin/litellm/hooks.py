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

        return data


drop_thinking_hook = DropThinkingHook()

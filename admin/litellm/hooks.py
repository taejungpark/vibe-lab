from litellm.integrations.custom_logger import CustomLogger
import litellm


class DropThinkingHook(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        data.pop("thinking", None)
        data.pop("budget_tokens", None)
        if isinstance(data.get("optional_params"), dict):
            data["optional_params"].pop("thinking", None)
            data["optional_params"].pop("budget_tokens", None)
        if isinstance(data.get("extra_body"), dict):
            data["extra_body"].pop("thinking", None)
            data["extra_body"].pop("budget_tokens", None)
        return data


drop_thinking_hook = DropThinkingHook()

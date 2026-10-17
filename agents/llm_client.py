"""
LLM client factory for wined3d-windows agents.

The Anthropic Python SDK reads these environment variables automatically:
  ANTHROPIC_API_KEY   — standard Anthropic key   (or use ANTHROPIC_AUTH_TOKEN for Z.AI)
  ANTHROPIC_BASE_URL  — override API base URL

Z.AI / GLM setup (values from your environment; the key never goes in a file here):
  export ANTHROPIC_AUTH_TOKEN=<your Z.AI API key>   # shell profile only, never in a file here
  export ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic

  Then run:  python3 orchestrator.py 8.0.2

Model selection via AGENT_MODEL env var:
  export AGENT_MODEL=glm-5.3      # default when Z.AI base URL is detected
  export AGENT_REASONING_EFFORT=high   # GLM reasoning effort: high (default) or max
  export AGENT_MODEL=claude-opus-4-5   # if using real Anthropic endpoint
"""

import os
from anthropic import Anthropic

# Models
DEFAULT_MODEL_ANTHROPIC = "claude-opus-4-5"
DEFAULT_MODEL_ZAI       = "glm-5.3"
DEFAULT_REASONING_EFFORT = "high"   # GLM-5.x: "high" or "max"

_ZAI_BASE = "z.ai"  # substring to detect Z.AI base URL


def get_client() -> Anthropic:
    """
    Return a configured Anthropic client.
    The SDK automatically picks up:
      ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN  → api_key
      ANTHROPIC_BASE_URL                         → base_url
    No extra code needed — just set the env vars before running.
    """
    auth_token = os.environ.get("ANTHROPIC_AUTH_TOKEN")
    if auth_token and not os.environ.get("ANTHROPIC_API_KEY"):
        # SDK prefers ANTHROPIC_API_KEY; set it from ANTHROPIC_AUTH_TOKEN if absent
        os.environ["ANTHROPIC_API_KEY"] = auth_token

    return Anthropic()


def get_model() -> str:
    """
    Return the model name to use.
    Checks AGENT_MODEL first, then infers from base URL.
    """
    override = os.environ.get("AGENT_MODEL")
    if override:
        return override

    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    if _ZAI_BASE in base_url:
        return DEFAULT_MODEL_ZAI

    return DEFAULT_MODEL_ANTHROPIC


def _is_glm(model: str) -> bool:
    return model.lower().startswith("glm")


def generation_kwargs(max_tokens: int) -> dict:
    """
    Extra arguments for client.messages.create().
    GLM: thinking on, reasoning effort from AGENT_REASONING_EFFORT (default
    "high"), passed through extra_body (Z.AI fields the Anthropic SDK does not
    model); reasoning tokens count toward max_tokens, so it gets headroom.
    Other models: just max_tokens.
    """
    if not _is_glm(get_model()):
        return {"max_tokens": max_tokens}
    effort = os.environ.get("AGENT_REASONING_EFFORT", DEFAULT_REASONING_EFFORT)
    return {
        "max_tokens": max(max_tokens, 16384),
        "extra_body": {"thinking": {"type": "enabled"}, "reasoning_effort": effort},
    }


def response_text(response) -> str:
    """Join the text blocks of a response (thinking blocks are skipped)."""
    return "".join(getattr(b, "text", "") for b in response.content
                   if getattr(b, "type", "text") == "text")

"""Providers for evaluation agents."""

AgentInfo = provider(
    doc = "Information about an evaluation agent.",
    fields = {
        "name": "Agent name (e.g., 'claude-code', 'openhands')",
        "version": "Agent version string",
        "runner": "Executable file that runs the agent",
        "runfiles": "Runfiles needed by the runner",
        "supports_model_override": "Whether agent accepts --model parameter",
        "default_model": "Default model to use if not specified",
        "environment_vars": "Dict of environment variables required by agent",
    },
)

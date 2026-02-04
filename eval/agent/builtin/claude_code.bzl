"""Claude Code agent for evaluations."""

load("//eval/agent:agent.bzl", "eval_agent")
load("@rules_claude//claude:defs.bzl", "CLAUDE_TOOLCHAIN_TYPE")

def _claude_code_runner_impl(ctx):
    """Creates a Claude Code agent runner script."""

    # Get the claude binary from the toolchain
    toolchain = ctx.toolchains[CLAUDE_TOOLCHAIN_TYPE]
    claude_binary = toolchain.claude_info.binary

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Claude Code agent runner
# Runs Claude Code CLI on the given instruction

set -euo pipefail

# Resolve to absolute path before any cd
CLAUDE_BIN="$PWD/{claude_binary_path}"
INSTRUCTION=""
WORKDIR=""
OUTPUT_DIR=""
TIMEOUT=300
MODEL="claude-sonnet-4-20250514"

while [[ $# -gt 0 ]]; do
    case $1 in
        --instruction) INSTRUCTION="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; shift ;;
    esac
done

if [ -z "$INSTRUCTION" ] || [ -z "$WORKDIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 --instruction <file> --workdir <dir> --output <dir> [--timeout <secs>] [--model <model>]"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Read instruction content
TASK_INSTRUCTION=$(cat "$INSTRUCTION")

# Run Claude Code
cd "$WORKDIR"

# Set HOME to workdir so Claude can write its config files in the sandbox
export HOME="$WORKDIR"

echo "Running Claude Code..."
echo "  Model: $MODEL"
echo "  Timeout: ${{TIMEOUT}}s"
echo "  Workdir: $WORKDIR"
echo ""

# Find timeout command (GNU timeout on Linux, gtimeout on macOS via homebrew)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

# Run with timeout if available, tee output so we can see it
if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$CLAUDE_BIN" \\
        --print \\
        --output-format json \\
        --model "$MODEL" \\
        --dangerously-skip-permissions \\
        "$TASK_INSTRUCTION" \\
        2>&1 | tee "$OUTPUT_DIR/output.log" \\
        || true
    EXIT_CODE=${{PIPESTATUS[0]}}
else
    # No timeout command available, run without timeout
    "$CLAUDE_BIN" \\
        --print \\
        --output-format json \\
        --model "$MODEL" \\
        --dangerously-skip-permissions \\
        "$TASK_INSTRUCTION" \\
        2>&1 | tee "$OUTPUT_DIR/output.log" \\
        || true
    EXIT_CODE=$?
fi

# Write completion status
echo "completed" > "$OUTPUT_DIR/status.txt"

# Show any errors
if [ -s "$OUTPUT_DIR/output.log" ]; then
    # Show last 20 lines of output
    echo ""
    echo "=== Agent Output (last 20 lines) ==="
    tail -20 "$OUTPUT_DIR/output.log"
fi

if [ "$EXIT_CODE" -eq 124 ]; then
    echo ""
    echo "ERROR: Agent timed out after ${{TIMEOUT}}s"
elif [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "ERROR: Agent exited with code $EXIT_CODE"
fi

echo ""
echo "Claude Code agent completed"
exit 0
""".format(claude_binary_path = claude_binary.path)

    ctx.actions.write(
        output = runner,
        content = script_content,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [claude_binary]),
    )]

_claude_code_runner = rule(
    implementation = _claude_code_runner_impl,
    executable = True,
    toolchains = [CLAUDE_TOOLCHAIN_TYPE],
)

def claude_code_agent(name, default_model = "claude-sonnet-4-20250514", **kwargs):
    """Creates a Claude Code agent.

    Runs the Claude Code CLI to complete evaluation tasks. Requires
    the ANTHROPIC_API_KEY environment variable to be set.

    Args:
        name: Name of the agent target.
        default_model: Default model to use (can be overridden per eval_run).
        **kwargs: Additional arguments passed to eval_agent.
    """
    runner_name = name + "_runner"

    _claude_code_runner(
        name = runner_name,
        visibility = ["//visibility:private"],
    )

    eval_agent(
        name = name,
        runner = ":" + runner_name,
        agent_name = "claude-code",
        version = "1.0.0",
        default_model = default_model,
        supports_model_override = True,
        env = {"ANTHROPIC_API_KEY": ""},
        **kwargs
    )

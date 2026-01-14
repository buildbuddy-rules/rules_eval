"""Claude Code agent for evaluations."""

load("//eval/agent:agent.bzl", "eval_agent")

def _claude_code_runner_impl(ctx):
    """Creates a Claude Code agent runner script."""

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Claude Code agent runner
# Runs Claude Code CLI on the given instruction

set -euo pipefail

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

echo "Running Claude Code..."
echo "  Model: $MODEL"
echo "  Timeout: ${TIMEOUT}s"
echo "  Workdir: $WORKDIR"
echo ""

# Check if claude CLI is available
if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI not found. Please install Claude Code."
    exit 1
fi

# Run with timeout
timeout "$TIMEOUT" claude \\
    --print \\
    --output-format json \\
    --model "$MODEL" \\
    --max-turns 50 \\
    "$TASK_INSTRUCTION" \\
    > "$OUTPUT_DIR/trajectory.json" 2> "$OUTPUT_DIR/stderr.log" \\
    || true

# Write completion status
echo "completed" > "$OUTPUT_DIR/status.txt"

echo "Claude Code agent completed"
exit 0
"""

    ctx.actions.write(
        output = runner,
        content = script_content,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = []),
    )]

_claude_code_runner = rule(
    implementation = _claude_code_runner_impl,
    executable = True,
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

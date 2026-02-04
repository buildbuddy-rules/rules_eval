"""Codex agent for evaluations."""

load("//eval/agent:agent.bzl", "eval_agent")
load("@rules_codex//codex:defs.bzl", "CODEX_TOOLCHAIN_TYPE")

def _codex_runner_impl(ctx):
    """Creates a Codex agent runner script."""

    # Get the codex binary from the toolchain
    toolchain = ctx.toolchains[CODEX_TOOLCHAIN_TYPE]
    codex_binary = toolchain.codex_info.binary

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Codex agent runner
# Runs OpenAI Codex CLI on the given instruction

set -euo pipefail

# Resolve to absolute path before any cd
CODEX_BIN="$PWD/{codex_binary_path}"
INSTRUCTION=""
WORKDIR=""
OUTPUT_DIR=""
TIMEOUT=300
MODEL=""

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

# Run Codex
cd "$WORKDIR"

# Set HOME to workdir so Codex can write its config files in the sandbox
export HOME="$WORKDIR"
export TMPDIR=/tmp
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH

# Pass OPENAI_API_KEY as CODEX_API_KEY (codex exec requires CODEX_API_KEY)
export CODEX_API_KEY="${{CODEX_API_KEY:-$OPENAI_API_KEY}}"

echo "Running Codex..."
if [ -n "$MODEL" ]; then
    echo "  Model: $MODEL"
fi
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
    "$TIMEOUT_CMD" "$TIMEOUT" "$CODEX_BIN" exec \\
        --dangerously-bypass-approvals-and-sandbox \\
        --skip-git-repo-check \\
        ${{MODEL:+--model "$MODEL"}} \\
        "$TASK_INSTRUCTION" \\
        2>&1 | tee "$OUTPUT_DIR/output.log" \\
        || true
    EXIT_CODE=${{PIPESTATUS[0]}}
else
    # No timeout command available, run without timeout
    "$CODEX_BIN" exec \\
        --dangerously-bypass-approvals-and-sandbox \\
        --skip-git-repo-check \\
        ${{MODEL:+--model "$MODEL"}} \\
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
echo "Codex agent completed"
exit 0
""".format(codex_binary_path = codex_binary.path)

    ctx.actions.write(
        output = runner,
        content = script_content,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [codex_binary]),
    )]

_codex_runner = rule(
    implementation = _codex_runner_impl,
    executable = True,
    toolchains = [CODEX_TOOLCHAIN_TYPE],
)

def codex_agent(name, default_model = "", **kwargs):
    """Creates a Codex agent.

    Runs the OpenAI Codex CLI to complete evaluation tasks. Requires
    the OPENAI_API_KEY environment variable to be set.

    Args:
        name: Name of the agent target.
        default_model: Default model to use (can be overridden per eval_run).
        **kwargs: Additional arguments passed to eval_agent.
    """
    runner_name = name + "_runner"

    _codex_runner(
        name = runner_name,
        visibility = ["//visibility:private"],
    )

    eval_agent(
        name = name,
        runner = ":" + runner_name,
        agent_name = "codex",
        version = "1.0.0",
        default_model = default_model,
        supports_model_override = True,
        env = {"OPENAI_API_KEY": ""},
        **kwargs
    )

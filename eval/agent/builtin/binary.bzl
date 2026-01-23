"""Binary agent - wraps a user-provided executable as an evaluation agent.

This agent type allows using any executable (e.g., go_binary, py_binary, etc.)
as an evaluation agent. The wrapper handles the standard eval infrastructure
concerns (workdir, output capture, timeout) so the binary can focus on the task.
"""

load("//eval/agent:agent.bzl", "eval_agent")

# Default invocation template - named args style
DEFAULT_INVOCATION = "{binary} --model {model} --prompt {instruction}"

def _parse_invocation_template(invocation):
    """Parse invocation template into shell script lines that build ARGS array."""
    args_lines = []
    parts = invocation.split(" ")
    skip_next = False

    for i, part in enumerate(parts):
        if skip_next:
            skip_next = False
            continue

        if part == "{binary}":
            continue
        elif part == "{instruction}":
            args_lines.append('ARGS+=("$TASK_INSTRUCTION")')
        elif part == "{instruction_file}":
            args_lines.append('ARGS+=("$INSTRUCTION")')
        elif part == "{model}":
            args_lines.append('if [ -n "$MODEL" ]; then ARGS+=("$MODEL"); fi')
        elif "{instruction}" in part or "{model}" in part or "{instruction_file}" in part:
            fail("Placeholders must be separate arguments, not embedded: " + part)
        else:
            # Check if next part is a placeholder to pair them
            next_part = parts[i + 1] if i + 1 < len(parts) else None
            if next_part == "{model}":
                args_lines.append('if [ -n "$MODEL" ]; then ARGS+=("' + part + '" "$MODEL"); fi')
                skip_next = True
            elif next_part == "{instruction}":
                args_lines.append('ARGS+=("' + part + '" "$TASK_INSTRUCTION")')
                skip_next = True
            elif next_part == "{instruction_file}":
                args_lines.append('ARGS+=("' + part + '" "$INSTRUCTION")')
                skip_next = True
            else:
                args_lines.append('ARGS+=("' + part + '")')

    return "\n".join(args_lines)

def _binary_agent_runner_impl(ctx):
    """Creates a wrapper script for a user-provided binary."""

    binary = ctx.executable.binary
    invocation = ctx.attr.invocation
    args_builder = _parse_invocation_template(invocation)

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Binary agent runner
# Wraps a user-provided executable as an evaluation agent

set -euo pipefail

# Resolve to absolute path before any cd
AGENT_BIN="$PWD/{binary_path}"
RUNFILES_DIR="${{AGENT_BIN}}.runfiles"
MANIFEST_FILE="${{AGENT_BIN}}.runfiles_manifest"

# Set up runfiles directory structure if manifest exists but runfiles dir doesn't
# This is needed for py_binary and similar rules when running in a Bazel action
if [ -f "$MANIFEST_FILE" ] && [ ! -d "$RUNFILES_DIR" ]; then
    mkdir -p "$RUNFILES_DIR"
    while IFS=' ' read -r runfiles_path actual_path; do
        if [ -n "$runfiles_path" ] && [ -n "$actual_path" ]; then
            target_path="$RUNFILES_DIR/$runfiles_path"
            mkdir -p "$(dirname "$target_path")"
            ln -sf "$actual_path" "$target_path"
        elif [ -n "$runfiles_path" ]; then
            # Empty file (no actual_path means create empty file)
            target_path="$RUNFILES_DIR/$runfiles_path"
            mkdir -p "$(dirname "$target_path")"
            touch "$target_path"
        fi
    done < "$MANIFEST_FILE"
fi

export RUNFILES_DIR
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

# Run in workdir
cd "$WORKDIR"

# Set HOME to workdir so agent can write config files in the sandbox
export HOME="$WORKDIR"

echo "Running binary agent..."
echo "  Model: ${{MODEL:-default}}"
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

# Build argument array
ARGS=()
{args_builder}

# Run with timeout if available, capture output
if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$AGENT_BIN" "${{ARGS[@]}}" \\
        2>&1 | tee "$OUTPUT_DIR/output.log" \\
        || true
    EXIT_CODE=${{PIPESTATUS[0]}}
else
    "$AGENT_BIN" "${{ARGS[@]}}" \\
        2>&1 | tee "$OUTPUT_DIR/output.log" \\
        || true
    EXIT_CODE=$?
fi

# Write completion status
echo "completed" > "$OUTPUT_DIR/status.txt"

# Show any errors
if [ -s "$OUTPUT_DIR/output.log" ]; then
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
echo "Binary agent completed"
exit 0
""".format(
        binary_path = binary.path,
        args_builder = args_builder,
    )

    ctx.actions.write(
        output = runner,
        content = script_content,
        is_executable = True,
    )

    # Collect runfiles from the binary target
    binary_runfiles = ctx.attr.binary[DefaultInfo].default_runfiles

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [binary]).merge(binary_runfiles),
    )]

_binary_agent_runner = rule(
    implementation = _binary_agent_runner_impl,
    executable = True,
    attrs = {
        "binary": attr.label(
            doc = "The executable to use as the agent.",
            executable = True,
            cfg = "target",
            mandatory = True,
        ),
        "invocation": attr.string(
            doc = "Template for invoking the binary. Placeholders: {binary}, {instruction}, {instruction_file}, {model}.",
            default = DEFAULT_INVOCATION,
        ),
    },
)

def binary_agent(
        name,
        binary,
        agent_name = None,
        invocation = DEFAULT_INVOCATION,
        default_model = "",
        supports_model_override = True,
        env = {},
        **kwargs):
    """Creates an agent from a user-provided binary.

    This allows using any executable (go_binary, py_binary, rust_binary, etc.)
    as an evaluation agent. The wrapper handles workdir setup, output capture,
    and timeout - the binary just needs to handle the instruction.

    The invocation template supports these placeholders:
        {binary}           - path to the agent binary
        {instruction}      - the instruction content (will be quoted)
        {instruction_file} - path to the instruction file
        {model}            - model name (e.g., "gpt-4")

    The wrapper handles:
    - Reading the instruction file
    - cd into the workdir
    - Setting HOME to workdir for sandbox compatibility
    - Timeout (via timeout/gtimeout command)
    - Capturing stdout/stderr to output.log
    - Writing status.txt

    Example usage:

        load("@rules_go//go:def.bzl", "go_binary")
        load("@rules_eval//eval:defs.bzl", "binary_agent")

        go_binary(name = "my_agent_bin", srcs = ["main.go"])

        # Default: named args (--model and --prompt)
        # Invokes: ./my_agent_bin --model gpt-4 --prompt "instruction..."
        binary_agent(
            name = "my_agent",
            binary = ":my_agent_bin",
        )

        # Positional instruction (like Claude Code)
        # Invokes: ./my_agent_bin "instruction..." --model gpt-4
        binary_agent(
            name = "my_agent_positional",
            binary = ":my_agent_bin",
            invocation = "{binary} {instruction} --model {model}",
        )

        # Subcommand style
        # Invokes: ./my_agent_bin run --prompt "instruction..." -m gpt-4
        binary_agent(
            name = "my_agent_subcmd",
            binary = ":my_agent_bin",
            invocation = "{binary} run --prompt {instruction} -m {model}",
        )

        # File path style
        # Invokes: ./my_agent_bin --file /path/to/instruction.md --model gpt-4
        binary_agent(
            name = "my_agent_file",
            binary = ":my_agent_bin",
            invocation = "{binary} --file {instruction_file} --model {model}",
        )

    Args:
        name: Name of the agent target.
        binary: Label of the executable to use as the agent.
        agent_name: Display name for the agent (defaults to target name).
        invocation: Template for invoking the binary. See placeholders above.
        default_model: Default model to use (can be overridden per eval_run).
        supports_model_override: Whether the binary accepts --model flag.
        env: Environment variables required by the agent (empty value = required at runtime).
        **kwargs: Additional arguments passed to eval_agent.
    """
    runner_name = name + "_runner"

    _binary_agent_runner(
        name = runner_name,
        binary = binary,
        invocation = invocation,
        visibility = ["//visibility:private"],
    )

    eval_agent(
        name = name,
        runner = ":" + runner_name,
        agent_name = agent_name if agent_name else name,
        version = "1.0.0",
        default_model = default_model,
        supports_model_override = supports_model_override,
        env = env,
        **kwargs
    )

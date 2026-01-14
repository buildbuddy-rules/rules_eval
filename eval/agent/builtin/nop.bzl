"""No-operation agent for testing the evaluation infrastructure."""

load("//eval/agent:agent.bzl", "eval_agent")

def _nop_runner_impl(ctx):
    """Creates a no-op agent runner script."""

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# NOP agent - does nothing, always "succeeds"
# Used for testing the evaluation infrastructure

set -euo pipefail

OUTPUT_DIR=""
INSTRUCTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --instruction) INSTRUCTION="$2"; shift 2 ;;
        --workdir) shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --timeout) shift 2 ;;
        --model) shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

# Write a minimal trajectory
echo '{"agent": "nop", "actions": [], "result": "nop"}' > "$OUTPUT_DIR/trajectory.json"
echo "nop" > "$OUTPUT_DIR/status.txt"

echo "NOP agent completed (did nothing)"
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

_nop_runner = rule(
    implementation = _nop_runner_impl,
    executable = True,
)

def nop_agent(name, **kwargs):
    """Creates a no-operation agent for testing.

    The nop agent does nothing and is used to test the evaluation
    infrastructure without making actual API calls.

    Args:
        name: Name of the agent target.
        **kwargs: Additional arguments passed to eval_agent.
    """
    runner_name = name + "_runner"

    _nop_runner(
        name = runner_name,
        visibility = ["//visibility:private"],
    )

    eval_agent(
        name = name,
        runner = ":" + runner_name,
        agent_name = "nop",
        version = "1.0.0",
        supports_model_override = False,
        **kwargs
    )

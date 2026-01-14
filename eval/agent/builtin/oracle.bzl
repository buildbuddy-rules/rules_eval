"""Oracle agent that applies the solution files from the task."""

load("//eval/agent:agent.bzl", "eval_agent")

def _oracle_runner_impl(ctx):
    """Creates an oracle agent runner script."""

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Oracle agent - runs solve.sh to generate the solution
# Used for testing tasks with known solutions

set -euo pipefail

OUTPUT_DIR=""
WORKDIR=""
SOLUTION_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --instruction) shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --timeout) shift 2 ;;
        --model) shift 2 ;;
        --solution-dir) SOLUTION_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

if [ -z "$SOLUTION_DIR" ] || [ ! -d "$SOLUTION_DIR" ]; then
    echo "Error: No solution directory provided or directory does not exist"
    echo "Oracle agent requires --solution-dir argument"
    exit 1
fi

if [ ! -f "$SOLUTION_DIR/solve.sh" ]; then
    echo "Error: No solve.sh found in solution directory"
    echo "Solution directory contents:"
    ls -la "$SOLUTION_DIR"
    exit 1
fi

# Run solve.sh from the workdir with solution dir available
echo "Running solve.sh from $SOLUTION_DIR"
cd "$WORKDIR"
chmod +x "$SOLUTION_DIR/solve.sh"
"$SOLUTION_DIR/solve.sh"

# Show result
echo ""
echo "Solution applied. Workdir contents:"
ls -la "$WORKDIR"

# Write trajectory
echo '{"agent": "oracle", "actions": ["run_solve_script"], "result": "solution_applied"}' > "$OUTPUT_DIR/trajectory.json"
echo "complete" > "$OUTPUT_DIR/status.txt"

echo ""
echo "Oracle agent completed (ran solve.sh)"
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

_oracle_runner = rule(
    implementation = _oracle_runner_impl,
    executable = True,
)

def oracle_agent(name, **kwargs):
    """Creates an oracle agent that applies task solutions.

    The oracle agent copies the solution files from the task to the workdir.
    This is useful for verifying that tasks are correctly configured and
    that the solution actually passes the tests.

    Args:
        name: Name of the agent target.
        **kwargs: Additional arguments passed to eval_agent.
    """
    runner_name = name + "_runner"

    _oracle_runner(
        name = runner_name,
        visibility = ["//visibility:private"],
    )

    eval_agent(
        name = name,
        runner = ":" + runner_name,
        agent_name = "oracle",
        version = "1.0.0",
        supports_model_override = False,
        **kwargs
    )

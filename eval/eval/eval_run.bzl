"""eval_run rule - build action that runs an agent on a task."""

load("//eval/task:providers.bzl", "TaskInfo")
load("//eval/agent:providers.bzl", "AgentInfo")
load(":providers.bzl", "EvalResultInfo")

def _eval_run_impl(ctx):
    """Implementation of eval_run rule - executes eval as a build action."""

    task_info = ctx.attr.task[TaskInfo]
    agent_info = ctx.attr.agent[AgentInfo]

    # Determine the model to use
    model = ctx.attr.model if ctx.attr.model else agent_info.default_model

    # Declare output files
    result_json = ctx.actions.declare_file(ctx.label.name + "_result.json")
    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Collect all input files
    inputs = []
    if task_info.instruction:
        inputs.append(task_info.instruction)
    if task_info.config:
        inputs.append(task_info.config)
    inputs.extend(task_info.environment_files.to_list())
    inputs.extend(task_info.test_files.to_list())

    # Add agent runner and its runfiles
    inputs.append(agent_info.runner)
    inputs.extend(agent_info.runfiles.files.to_list())

    # Build the command that runs the eval
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [result_json],
        command = """
set -euo pipefail

TASK_NAME="{task_name}"
INSTRUCTION="{instruction_path}"
AGENT_RUNNER="{agent_runner_path}"
MODEL="{model}"
AGENT_NAME="{agent_name}"
RESULT_JSON_REL="{result_json_path}"
RESULT_JSON="$PWD/$RESULT_JSON_REL"
AGENT_TIMEOUT="{agent_timeout}"

# Create output parent directory
mkdir -p "$(dirname "$RESULT_JSON")"

# Create working directories
WORKDIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
trap "rm -rf $WORKDIR $OUTPUT_DIR" EXIT

# Copy environment files to workdir
{copy_env_files}

# Copy test files
{copy_test_files}

# Create output directories
mkdir -p "$OUTPUT_DIR/agent"
mkdir -p "$OUTPUT_DIR/verifier"

# Run the agent
AGENT_ARGS="--instruction $INSTRUCTION --workdir $WORKDIR --output $OUTPUT_DIR/agent --timeout $AGENT_TIMEOUT"
if [ -n "$MODEL" ]; then
    AGENT_ARGS="$AGENT_ARGS --model $MODEL"
fi

"$AGENT_RUNNER" $AGENT_ARGS || true

# Run verification
cd "$WORKDIR"
REWARD=0

# Look for test.sh in the tests directory
if [ -f "$OUTPUT_DIR/tests/test.sh" ]; then
    chmod +x "$OUTPUT_DIR/tests/test.sh"
    if "$OUTPUT_DIR/tests/test.sh" > "$OUTPUT_DIR/verifier/stdout.txt" 2> "$OUTPUT_DIR/verifier/stderr.txt"; then
        REWARD=1
    fi
fi

# Check for reward.txt or reward.json
if [ -f "$WORKDIR/reward.txt" ]; then
    REWARD=$(cat "$WORKDIR/reward.txt" | head -1)
elif [ -f "$WORKDIR/reward.json" ]; then
    REWARD=$(cat "$WORKDIR/reward.json" | grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' | grep -o '[0-9.]*$' || echo "0")
fi

# Determine pass/fail
if [ "$REWARD" = "1" ] || [ "$REWARD" = "1.0" ]; then
    PASSED=true
else
    PASSED=false
fi

# Write result JSON (output path is set up by Bazel sandbox)
cat > "$RESULT_JSON" << EOF
{{
  "task": "$TASK_NAME",
  "agent": "$AGENT_NAME",
  "model": "$MODEL",
  "reward": $REWARD,
  "passed": $PASSED
}}
EOF
""".format(
            task_name = task_info.name,
            instruction_path = task_info.instruction.path if task_info.instruction else "",
            agent_runner_path = agent_info.runner.path,
            model = model,
            agent_name = agent_info.name,
            result_json_path = result_json.path,
            agent_timeout = task_info.timeout_secs,
            copy_env_files = _generate_copy_commands(task_info.environment_files.to_list(), "$WORKDIR"),
            copy_test_files = _generate_copy_commands(task_info.test_files.to_list(), "$OUTPUT_DIR/tests"),
        ),
        mnemonic = "EvalRun",
        progress_message = "Running eval: %s with %s" % (task_info.name, agent_info.name),
        execution_requirements = {
            "requires-network": "1",
            "no-cache": "1",
            "no-remote": "1",
        },
    )

    # Create the runner script that displays the result
    runner_content = '''#!/bin/bash
# Get runfiles directory
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
cd "$RUNFILES_DIR/_main" 2>/dev/null || cd "$RUNFILES_DIR" 2>/dev/null || true

RESULT_FILE="{result_path}"

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
CYAN='\\033[0;36m'
NC='\\033[0m'
BOLD='\\033[1m'

if [ ! -f "$RESULT_FILE" ]; then
    echo -e "${{RED}}Error: Result file not found${{NC}}"
    exit 1
fi

# Parse JSON
TASK=$(grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
AGENT=$(grep -o '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
MODEL=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
PASS=$(grep -o '"passed"[[:space:]]*:[[:space:]]*[a-z]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')
REWARD=$(grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')

echo ""
echo -e "${{BOLD}}Eval Result${{NC}}"
echo "==========="
echo ""
echo -e "  ${{CYAN}}Task:${{NC}}   $TASK"
echo -e "  ${{CYAN}}Agent:${{NC}}  $AGENT"
if [ -n "$MODEL" ]; then
    echo -e "  ${{CYAN}}Model:${{NC}}  $MODEL"
fi
echo ""

if [ "$PASS" = "true" ]; then
    echo -e "  ${{GREEN}}${{BOLD}}PASSED${{NC}}  (reward: $REWARD)"
else
    echo -e "  ${{RED}}${{BOLD}}FAILED${{NC}}  (reward: $REWARD)"
fi
echo ""

# Exit with appropriate code
if [ "$PASS" = "true" ]; then
    exit 0
else
    exit 1
fi
'''.format(result_path = result_json.short_path)

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    # Collect runfiles
    runfiles = ctx.runfiles(files = [result_json])

    return [
        DefaultInfo(
            executable = runner,
            files = depset([result_json]),
            runfiles = runfiles,
        ),
        EvalResultInfo(
            task_label = ctx.attr.task.label,
            agent_label = ctx.attr.agent.label,
            model = model,
            result_json = result_json,
        ),
    ]

def _generate_copy_commands(files, dest_dir):
    """Generate shell commands to copy files to a destination directory."""
    if not files:
        return "mkdir -p " + dest_dir

    commands = ["mkdir -p " + dest_dir]
    for f in files:
        commands.append('cp "{src}" "{dest}/"'.format(src = f.path, dest = dest_dir))
    return "\n".join(commands)

_eval_run = rule(
    implementation = _eval_run_impl,
    doc = "Runs an agent on a task as a build action, outputting result JSON.",
    executable = True,
    attrs = {
        "task": attr.label(
            doc = "The eval_task to run.",
            providers = [TaskInfo],
            mandatory = True,
        ),
        "agent": attr.label(
            doc = "The eval_agent to use.",
            providers = [AgentInfo],
            mandatory = True,
        ),
        "model": attr.string(
            doc = "Model to use (overrides agent default).",
            default = "",
        ),
    },
)

def eval_run(name, task, agent, model = "", **kwargs):
    """Runs an agent on a task as a build action.

    When built with `bazel build`, this target executes the agent on the task
    and outputs a result JSON file. When run with `bazel run`, it displays
    a formatted summary of the eval result.

    Args:
        name: Name of the target.
        task: Label of the eval_task to run.
        agent: Label of the eval_agent to use.
        model: Optional model override (defaults to agent's default model).
        **kwargs: Additional arguments passed to the underlying rule.

    Example:
        # Build the eval (runs agent and generates result)
        bazel build //evals:my_eval

        # Run and display formatted result
        bazel run //evals:my_eval
    """
    _eval_run(
        name = name,
        task = task,
        agent = agent,
        model = model,
        **kwargs
    )

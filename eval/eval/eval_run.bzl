"""eval_run rule - build action that runs an agent on a task."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//eval/task:providers.bzl", "TaskInfo")
load("//eval/agent:providers.bzl", "AgentInfo")
load(":providers.bzl", "EvalResultInfo")

def _eval_run_impl(ctx):
    """Implementation of eval_run rule - executes eval as a build action."""

    task_info = ctx.attr.task[TaskInfo]
    agent_info = ctx.attr.agent[AgentInfo]

    # Determine the model to use
    model = ctx.attr.model if ctx.attr.model else agent_info.default_model

    # Determine run_count: command-line flag overrides BUILD file attribute
    flag_run_count = ctx.attr._run_count_flag[BuildSettingInfo].value
    if flag_run_count > 0:
        run_count = flag_run_count
    else:
        run_count = ctx.attr.run_count

    # Collect all input files (shared across runs)
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

    # Only include solution files for oracle agent
    solution_files = []
    if agent_info.name == "oracle":
        solution_files = task_info.solution_files.to_list()
        inputs.extend(solution_files)

    # Create an action for each run
    result_jsons = []
    trajectory_files = []
    for run_idx in range(1, run_count + 1):
        result_json = ctx.actions.declare_file(
            "{}_run_{}_result.json".format(ctx.label.name, run_idx),
        )
        trajectory_file = ctx.actions.declare_file(
            "{}_run_{}_trajectory.txt".format(ctx.label.name, run_idx),
        )
        result_jsons.append(result_json)
        trajectory_files.append(trajectory_file)

        # Build the command that runs the eval
        # Include run_idx in the command to make each action unique
        ctx.actions.run_shell(
            inputs = inputs,
            outputs = [result_json, trajectory_file],
            command = """
set -euo pipefail

TASK_NAME="{task_name}"
INSTRUCTION="{instruction_path}"
AGENT_RUNNER="{agent_runner_path}"
MODEL="{model}"
AGENT_NAME="{agent_name}"
RESULT_JSON_REL="{result_json_path}"
RESULT_JSON="$PWD/$RESULT_JSON_REL"
TRAJECTORY_REL="{trajectory_path}"
TRAJECTORY="$PWD/$TRAJECTORY_REL"
AGENT_TIMEOUT="{agent_timeout}"
RUN_INDEX="{run_index}"

# Create output parent directory
mkdir -p "$(dirname "$RESULT_JSON")"
mkdir -p "$(dirname "$TRAJECTORY")"

# Create working directories
WORKDIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
trap "rm -rf $WORKDIR $OUTPUT_DIR" EXIT

# Copy environment files to workdir
{copy_env_files}

# Copy test files
{copy_test_files}

# Copy solution files (only present for oracle agent)
{copy_solution_files}

# Create output directories
mkdir -p "$OUTPUT_DIR/agent"
mkdir -p "$OUTPUT_DIR/verifier"

# Run the agent and capture output
AGENT_ARGS="--instruction $INSTRUCTION --workdir $WORKDIR --output $OUTPUT_DIR/agent --timeout $AGENT_TIMEOUT"
if [ -n "$MODEL" ]; then
    AGENT_ARGS="$AGENT_ARGS --model $MODEL"
fi
if [ -d "$OUTPUT_DIR/solution" ] && [ "$AGENT_NAME" = "oracle" ]; then
    AGENT_ARGS="$AGENT_ARGS --solution-dir $OUTPUT_DIR/solution"
fi

AGENT_EXIT_CODE=0
"$AGENT_RUNNER" $AGENT_ARGS > "$OUTPUT_DIR/agent/stdout.txt" 2> "$OUTPUT_DIR/agent/stderr.txt" || AGENT_EXIT_CODE=$?

# Run verification
cd "$WORKDIR"
REWARD=0
VERIFIER_OUTPUT=""

# Look for test.sh in the tests directory
if [ -f "$OUTPUT_DIR/tests/test.sh" ]; then
    chmod +x "$OUTPUT_DIR/tests/test.sh"
    if "$OUTPUT_DIR/tests/test.sh" > "$OUTPUT_DIR/verifier/stdout.txt" 2> "$OUTPUT_DIR/verifier/stderr.txt"; then
        REWARD=1
    fi
    VERIFIER_OUTPUT=$(cat "$OUTPUT_DIR/verifier/stdout.txt" "$OUTPUT_DIR/verifier/stderr.txt" 2>/dev/null | head -20 || true)
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

# Capture agent output (tail)
AGENT_OUTPUT=""
if [ -f "$OUTPUT_DIR/agent/stdout.txt" ]; then
    AGENT_OUTPUT=$(tail -50 "$OUTPUT_DIR/agent/stdout.txt" 2>/dev/null || true)
fi
if [ -f "$OUTPUT_DIR/agent/stderr.txt" ] && [ -s "$OUTPUT_DIR/agent/stderr.txt" ]; then
    AGENT_STDERR=$(tail -20 "$OUTPUT_DIR/agent/stderr.txt" 2>/dev/null || true)
    if [ -n "$AGENT_STDERR" ]; then
        AGENT_OUTPUT="$AGENT_OUTPUT
[stderr] $AGENT_STDERR"
    fi
fi

# Escape special characters for JSON
escape_json() {{
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}}

VERIFIER_OUTPUT_JSON=$(escape_json "$VERIFIER_OUTPUT")
AGENT_OUTPUT_JSON=$(escape_json "$AGENT_OUTPUT")

# Write trajectory file
echo "=== Agent Trajectory ===" > "$TRAJECTORY"
echo "Task: $TASK_NAME" >> "$TRAJECTORY"
echo "Agent: $AGENT_NAME" >> "$TRAJECTORY"
echo "Model: $MODEL" >> "$TRAJECTORY"
echo "Run: $RUN_INDEX" >> "$TRAJECTORY"
echo "" >> "$TRAJECTORY"
echo "=== Agent Output ===" >> "$TRAJECTORY"
if [ -f "$OUTPUT_DIR/agent/stdout.txt" ]; then
    cat "$OUTPUT_DIR/agent/stdout.txt" >> "$TRAJECTORY"
fi
if [ -f "$OUTPUT_DIR/agent/stderr.txt" ] && [ -s "$OUTPUT_DIR/agent/stderr.txt" ]; then
    echo "" >> "$TRAJECTORY"
    echo "=== Agent Stderr ===" >> "$TRAJECTORY"
    cat "$OUTPUT_DIR/agent/stderr.txt" >> "$TRAJECTORY"
fi
echo "" >> "$TRAJECTORY"
echo "=== Verifier Output ===" >> "$TRAJECTORY"
if [ -f "$OUTPUT_DIR/verifier/stdout.txt" ]; then
    cat "$OUTPUT_DIR/verifier/stdout.txt" >> "$TRAJECTORY"
fi
if [ -f "$OUTPUT_DIR/verifier/stderr.txt" ] && [ -s "$OUTPUT_DIR/verifier/stderr.txt" ]; then
    echo "" >> "$TRAJECTORY"
    echo "=== Verifier Stderr ===" >> "$TRAJECTORY"
    cat "$OUTPUT_DIR/verifier/stderr.txt" >> "$TRAJECTORY"
fi
echo "" >> "$TRAJECTORY"
echo "=== Workdir Contents ===" >> "$TRAJECTORY"
ls -la "$WORKDIR" >> "$TRAJECTORY" 2>/dev/null || true

# Write result JSON
cat > "$RESULT_JSON" << EOF
{{
  "task": "$TASK_NAME",
  "agent": "$AGENT_NAME",
  "model": "$MODEL",
  "run": $RUN_INDEX,
  "reward": $REWARD,
  "passed": $PASSED,
  "trajectory": "{trajectory_short_path}",
  "agent_output": $AGENT_OUTPUT_JSON,
  "verifier_output": $VERIFIER_OUTPUT_JSON
}}
EOF
""".format(
                task_name = task_info.name,
                instruction_path = task_info.instruction.path if task_info.instruction else "",
                agent_runner_path = agent_info.runner.path,
                model = model,
                agent_name = agent_info.name,
                result_json_path = result_json.path,
                trajectory_path = trajectory_file.path,
                trajectory_short_path = trajectory_file.short_path,
                agent_timeout = task_info.timeout_secs,
                run_index = run_idx,
                copy_env_files = _generate_copy_commands(task_info.environment_files.to_list(), "$WORKDIR"),
                copy_test_files = _generate_copy_commands(task_info.test_files.to_list(), "$OUTPUT_DIR/tests"),
                copy_solution_files = _generate_copy_commands(solution_files, "$OUTPUT_DIR/solution"),
            ),
            mnemonic = "EvalRun",
            progress_message = "Running eval: %s with %s (run %d/%d)" % (task_info.name, agent_info.name, run_idx, run_count),
            use_default_shell_env = True,
            execution_requirements = {
                "requires-network": "1",
            },
        )

    # Create the runner script that displays all results
    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Build list of result file paths for the runner
    result_paths = " ".join(['"{}"'.format(f.short_path) for f in result_jsons])

    runner_content = '''#!/bin/bash
# Get runfiles directory
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
cd "$RUNFILES_DIR/_main" 2>/dev/null || cd "$RUNFILES_DIR" 2>/dev/null || true

RESULT_FILES=({result_paths})

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
CYAN='\\033[0;36m'
YELLOW='\\033[1;33m'
DIM='\\033[2m'
NC='\\033[0m'
BOLD='\\033[1m'

TOTAL=0
PASSED=0
TOTAL_REWARD=0

# First pass: collect metadata from first file and count results
TASK=""
AGENT=""
MODEL=""

for RESULT_FILE in "${{RESULT_FILES[@]}}"; do
    if [ -f "$RESULT_FILE" ]; then
        if [ -z "$TASK" ]; then
            TASK=$(grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
            AGENT=$(grep -o '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
            MODEL=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        fi

        PASS=$(grep -o '"passed"[[:space:]]*:[[:space:]]*[a-z]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')
        REWARD=$(grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')

        TOTAL=$((TOTAL + 1))
        if [ "$PASS" = "true" ]; then
            PASSED=$((PASSED + 1))
        fi
        TOTAL_REWARD=$(echo "$TOTAL_REWARD + $REWARD" | bc)
    fi
done

echo ""
echo -e "${{BOLD}}Eval Result${{NC}}"
echo "==========="
echo ""
echo -e "  ${{CYAN}}Task:${{NC}}   $TASK"
echo -e "  ${{CYAN}}Agent:${{NC}}  $AGENT"
if [ -n "$MODEL" ]; then
    echo -e "  ${{CYAN}}Model:${{NC}}  $MODEL"
fi
echo -e "  ${{CYAN}}Runs:${{NC}}   $TOTAL"
echo ""

# Show individual run results
echo -e "${{BOLD}}Runs:${{NC}}"
RUN_NUM=0
for RESULT_FILE in "${{RESULT_FILES[@]}}"; do
    if [ -f "$RESULT_FILE" ]; then
        RUN_NUM=$((RUN_NUM + 1))
        PASS=$(grep -o '"passed"[[:space:]]*:[[:space:]]*[a-z]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')
        REWARD=$(grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' "$RESULT_FILE" | sed 's/.*:[[:space:]]*//')
        TRAJECTORY=$(grep -o '"trajectory"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | sed 's/.*"\\([^"]*\\)"$/\\1/')

        if [ "$PASS" = "true" ]; then
            echo -e "  Run $RUN_NUM: ${{GREEN}}PASS${{NC}} (reward: $REWARD)"
        else
            echo -e "  Run $RUN_NUM: ${{RED}}FAIL${{NC}} (reward: $REWARD)"

            # Show agent output and verifier output for failed runs
            # Strip ANSI escape codes for cleaner display
            python3 -c "
import json, re
def strip_ansi(s):
    return re.sub(r'\\x1b\\[[0-9;]*m', '', s)
with open('$RESULT_FILE') as f:
    data = json.load(f)
    agent_out = strip_ansi(data.get('agent_output', '')).strip()
    verifier_out = strip_ansi(data.get('verifier_output', '')).strip()
    if agent_out:
        # Skip status messages, show last 3 meaningful lines
        lines = [l for l in agent_out.split('\\n') if l.strip()]
        # Filter out common status messages
        skip_prefixes = ('Running ', 'Claude Code agent', 'Codex agent', '===', 'ERROR:', 'Model:', 'Timeout:', 'Workdir:')
        meaningful = [l for l in lines if not any(l.strip().startswith(p) for p in skip_prefixes)]
        if not meaningful:
            meaningful = lines  # fallback to all lines if filtering removes everything
        for line in meaningful[-3:]:
            print(f'         \\033[2mAgent: {{line[:200]}}\\033[0m')
    if verifier_out:
        lines = [l for l in verifier_out.split('\\n') if l.strip()]
        if lines:
            print(f'         \\033[2mVerifier: {{lines[0][:200]}}\\033[0m')
" 2>/dev/null || true

            # Show trajectory link
            if [ -n "$TRAJECTORY" ]; then
                echo -e "         ${{DIM}}Trajectory: bazel-bin/$TRAJECTORY${{NC}}"
            fi
        fi
    fi
done

echo ""

# Summary
if [ $TOTAL -gt 0 ]; then
    PASS_RATE=$(echo "scale=1; $PASSED * 100 / $TOTAL" | bc)
    AVG_REWARD=$(echo "scale=2; $TOTAL_REWARD / $TOTAL" | bc)
else
    PASS_RATE="0.0"
    AVG_REWARD="0.00"
fi

FAILED=$((TOTAL - PASSED))

echo -e "${{BOLD}}Summary:${{NC}} ${{GREEN}}$PASSED passed${{NC}}, ${{RED}}$FAILED failed${{NC}} ($PASS_RATE%)"
echo -e "         avg reward: $AVG_REWARD"
echo ""

# Exit with failure if any run failed
if [ $FAILED -gt 0 ]; then
    exit 1
fi
'''.format(result_paths = result_paths)

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    # Collect runfiles (include both results and trajectories)
    runfiles = ctx.runfiles(files = result_jsons + trajectory_files)

    return [
        DefaultInfo(
            executable = runner,
            files = depset(result_jsons + trajectory_files),
            runfiles = runfiles,
        ),
        EvalResultInfo(
            task_label = ctx.attr.task.label,
            agent_label = ctx.attr.agent.label,
            model = model,
            result_jsons = result_jsons,
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
        "run_count": attr.int(
            doc = "Number of evaluation runs. Each run is a separate cached action.",
            default = 1,
        ),
        "_run_count_flag": attr.label(
            default = "//flag:run_count",
            providers = [BuildSettingInfo],
        ),
    },
)

def eval_run(name, task, agent, model = "", run_count = 1, **kwargs):
    """Runs an agent on a task as a build action.

    When built with `bazel build`, this target executes the agent on the task
    and outputs result JSON files (one per run). When run with `bazel run`,
    it displays a formatted summary of all eval results.

    Each run is a separate Bazel action, so increasing run_count will only
    execute the new runs - previous runs are cached.

    The run_count can also be set via command-line flag, which overrides
    the BUILD file value:
        bazel run //evals:my_eval --//flag:run_count=10

    Args:
        name: Name of the target.
        task: Label of the eval_task to run.
        agent: Label of the eval_agent to use.
        model: Optional model override (defaults to agent's default model).
        run_count: Number of evaluation runs (default 1).
        **kwargs: Additional arguments passed to the underlying rule.

    Example:
        eval_run(
            name = "my_eval",
            task = "//tasks:hello_world",
            agent = "//agents:claude_code",
            run_count = 5,  # Run 5 times
        )

        # Build the eval (runs agent 5 times)
        bazel build //evals:my_eval

        # Run and display formatted results
        bazel run //evals:my_eval

        # Override run_count from command line
        bazel run //evals:my_eval --//flag:run_count=10
    """
    _eval_run(
        name = name,
        task = task,
        agent = agent,
        model = model,
        run_count = run_count,
        **kwargs
    )

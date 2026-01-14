"""eval_run rule - test target that runs an agent on a task."""

load("//eval/task:providers.bzl", "TaskInfo")
load("//eval/agent:providers.bzl", "AgentInfo")
load(":providers.bzl", "EvalResultInfo")

def _run_eval_test_impl(ctx):
    """Implementation of run_eval_test rule."""

    task_info = ctx.attr.task[TaskInfo]
    agent_info = ctx.attr.agent[AgentInfo]

    # Determine the model to use
    model = ctx.attr.model if ctx.attr.model else agent_info.default_model

    # Create the test runner script
    runner_script = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Collect all input files for the test
    task_files = []
    if task_info.instruction:
        task_files.append(task_info.instruction)
    if task_info.config:
        task_files.append(task_info.config)

    # Build file lists for the runner
    env_files_list = task_info.environment_files.to_list()
    test_files_list = task_info.test_files.to_list()

    # Create environment files manifest
    env_manifest = ctx.actions.declare_file(ctx.label.name + "_env_manifest.txt")
    ctx.actions.write(
        output = env_manifest,
        content = "\n".join([f.short_path for f in env_files_list]),
    )

    # Create test files manifest
    test_manifest = ctx.actions.declare_file(ctx.label.name + "_test_manifest.txt")
    ctx.actions.write(
        output = test_manifest,
        content = "\n".join([f.short_path for f in test_files_list]),
    )

    # Get the eval_runner path
    eval_runner = ctx.executable._eval_runner
    agent_runner = agent_info.runner

    # Create the test wrapper script
    # Note: Timeout is handled by Bazel's test framework
    script_content = """#!/bin/bash
set -euo pipefail

# Get script directory for finding files
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
cd "$RUNFILES_DIR/_main" 2>/dev/null || cd "$RUNFILES_DIR" 2>/dev/null || true

# Configuration
TASK_NAME="{task_name}"
INSTRUCTION="{instruction_path}"
ENV_MANIFEST="{env_manifest_path}"
TEST_MANIFEST="{test_manifest_path}"
AGENT_RUNNER="{agent_runner_path}"
MODEL="{model}"

# Create working directories
WORKDIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
trap "rm -rf $WORKDIR $OUTPUT_DIR" EXIT

# Copy environment files to workdir
if [ -f "$ENV_MANIFEST" ]; then
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "$file" ]; then
            dir=$(dirname "$file")
            mkdir -p "$WORKDIR/$dir"
            cp "$file" "$WORKDIR/$file"
        fi
    done < "$ENV_MANIFEST"
fi

# Copy test files to output dir for verification
mkdir -p "$OUTPUT_DIR/tests"
if [ -f "$TEST_MANIFEST" ]; then
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "$file" ]; then
            cp "$file" "$OUTPUT_DIR/tests/"
        fi
    done < "$TEST_MANIFEST"
fi

# Create output directories
mkdir -p "$OUTPUT_DIR/agent"
mkdir -p "$OUTPUT_DIR/verifier"

# Run the agent
echo "Running agent: $TASK_NAME"
AGENT_ARGS="--instruction $INSTRUCTION --workdir $WORKDIR --output $OUTPUT_DIR/agent --timeout {agent_timeout}"
if [ -n "$MODEL" ]; then
    AGENT_ARGS="$AGENT_ARGS --model $MODEL"
fi

"$AGENT_RUNNER" $AGENT_ARGS || true

# Run verification
echo "Running verification..."
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

# Write result
echo '{{"task": "{task_name}", "agent": "{agent_name}", "model": "{model}", "reward": '"$REWARD"'}}' > "$OUTPUT_DIR/result.json"

# Determine pass/fail
if [ "$REWARD" = "1" ] || [ "$REWARD" = "1.0" ]; then
    echo "PASSED: reward=$REWARD"
    exit 0
else
    echo "FAILED: reward=$REWARD"
    exit 1
fi
""".format(
        task_name = task_info.name,
        instruction_path = task_info.instruction.short_path if task_info.instruction else "",
        env_manifest_path = env_manifest.short_path,
        test_manifest_path = test_manifest.short_path,
        agent_runner_path = agent_runner.short_path,
        agent_timeout = task_info.timeout_secs,
        model = model,
        agent_name = agent_info.name,
    )

    ctx.actions.write(
        output = runner_script,
        content = script_content,
        is_executable = True,
    )

    # Collect all runfiles
    runfiles_files = (
        task_files +
        env_files_list +
        test_files_list +
        [env_manifest, test_manifest]
    )

    runfiles = ctx.runfiles(files = runfiles_files)
    runfiles = runfiles.merge(agent_info.runfiles)
    runfiles = runfiles.merge(ctx.attr._eval_runner[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = runner_script,
            runfiles = runfiles,
        ),
        EvalResultInfo(
            task_label = ctx.attr.task.label,
            agent_label = ctx.attr.agent.label,
            model = model,
            result_json = None,  # Created at runtime
        ),
        testing.TestEnvironment({
            "EVAL_TASK": task_info.name,
            "EVAL_AGENT": agent_info.name,
            "EVAL_MODEL": model,
        }),
    ]

_run_eval_test = rule(
    implementation = _run_eval_test_impl,
    doc = "Runs an agent on a task and verifies the result. This is a test target.",
    test = True,
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
        "_eval_runner": attr.label(
            doc = "The evaluation runner script.",
            default = "//eval/private:eval_runner",
            executable = True,
            cfg = "target",
        ),
    },
)

def eval_run(name, task, agent, model = "", tags = [], **kwargs):
    """Creates a test target that runs an agent on a task.

    This is the main macro for creating evaluation test targets.
    Each eval_run target can be executed with `bazel test`.

    Args:
        name: Name of the test target.
        task: Label of the eval_task to run.
        agent: Label of the eval_agent to use.
        model: Optional model override (defaults to agent's default model).
        tags: Tags to apply to the test target.
        **kwargs: Additional arguments passed to the underlying test rule.

    Example:
        eval_run(
            name = "hello_world_claude",
            task = "//tasks:hello_world",
            agent = "//agents:claude_code",
            model = "claude-opus-4-20250514",
        )
    """
    _run_eval_test(
        name = name,
        task = task,
        agent = agent,
        model = model,
        tags = tags + ["eval"],
        **kwargs
    )

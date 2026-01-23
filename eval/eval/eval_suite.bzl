"""eval_suite rule - executable that aggregates and displays eval results."""

load(":providers.bzl", "EvalResultInfo")

def _eval_suite_impl(ctx):
    """Implementation of eval_suite rule."""

    # Collect all result JSON files from eval_run targets
    result_files = []
    for run in ctx.attr.runs:
        if EvalResultInfo in run:
            result_files.extend(run[EvalResultInfo].result_jsons)

    # Create a manifest of result files
    manifest = ctx.actions.declare_file(ctx.label.name + "_manifest.txt")
    ctx.actions.write(
        output = manifest,
        content = "\n".join([f.short_path for f in result_files]) + "\n",
    )

    # Create the runner script that displays results
    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    script_content = '''#!/bin/bash
set -euo pipefail

# Get runfiles directory
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
cd "$RUNFILES_DIR/_main" 2>/dev/null || cd "$RUNFILES_DIR" 2>/dev/null || true

MANIFEST="{manifest_path}"

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
DIM='\\033[2m'
NC='\\033[0m' # No Color
BOLD='\\033[1m'

# Create temp files
TMPFILE=$(mktemp)
FAILED_FILE=$(mktemp)
trap "rm -f $TMPFILE $FAILED_FILE $TMPFILE.totals" EXIT

# First pass: collect results and track failures
while IFS= read -r result_file; do
    if [ -n "$result_file" ] && [ -f "$result_file" ]; then
        TASK=$(grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        AGENT=$(grep -o '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        MODEL=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        PASS=$(grep -o '"passed"[[:space:]]*:[[:space:]]*[a-z]*' "$result_file" | sed 's/.*:[[:space:]]*//')
        REWARD=$(grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' "$result_file" | sed 's/.*:[[:space:]]*//')
        RUN_NUM=$(grep -o '"run"[[:space:]]*:[[:space:]]*[0-9]*' "$result_file" | sed 's/.*:[[:space:]]*//')

        PASS_NUM=0
        if [ "$PASS" = "true" ]; then
            PASS_NUM=1
        else
            # Track failed runs for detail section
            echo "$result_file" >> "$FAILED_FILE"
        fi

        echo "$TASK|$AGENT|$MODEL|$PASS_NUM|$REWARD" >> "$TMPFILE"
    fi
done < "$MANIFEST"

# Show failed run details first
if [ -s "$FAILED_FILE" ]; then
    echo ""
    echo -e "${{BOLD}}Failed Runs:${{NC}}"
    echo ""

    while IFS= read -r result_file; do
        if [ -f "$result_file" ]; then
            TASK=$(grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
            AGENT=$(grep -o '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
            MODEL=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
            RUN_NUM=$(grep -o '"run"[[:space:]]*:[[:space:]]*[0-9]*' "$result_file" | sed 's/.*:[[:space:]]*//')
            TRAJECTORY=$(grep -o '"trajectory"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')

            # Get agent and verifier output using python for proper JSON parsing
            # Strip ANSI escape codes for cleaner display
            AGENT_OUT=$(python3 -c "
import json, re
def strip_ansi(s):
    return re.sub(r'\\x1b\\[[0-9;]*m', '', s)
with open('$result_file') as f:
    data = json.load(f)
    v = strip_ansi(data.get('agent_output', ''))
    if v:
        # Skip status messages, show last 3 meaningful lines
        lines = [l for l in v.strip().split('\\n') if l.strip()]
        skip_prefixes = ('Running ', 'Claude Code agent', 'Codex agent', '===', 'ERROR:', 'Model:', 'Timeout:', 'Workdir:')
        meaningful = [l for l in lines if not any(l.strip().startswith(p) for p in skip_prefixes)]
        if not meaningful:
            meaningful = lines
        for line in meaningful[-3:]:
            print(line[:200])
" 2>/dev/null || true)

            VERIFIER_OUT=$(python3 -c "
import json, re
def strip_ansi(s):
    return re.sub(r'\\x1b\\[[0-9;]*m', '', s)
with open('$result_file') as f:
    data = json.load(f)
    v = strip_ansi(data.get('verifier_output', ''))
    if v:
        print(v[:200])
" 2>/dev/null || true)

            MODEL_SHORT=$(echo "$MODEL" | sed 's/claude-//' | cut -c1-20)
            if [ -n "$MODEL_SHORT" ]; then
                echo -e "  ${{RED}}$TASK${{NC}} / $AGENT / $MODEL_SHORT (run $RUN_NUM)"
            else
                echo -e "  ${{RED}}$TASK${{NC}} / $AGENT (run $RUN_NUM)"
            fi

            if [ -n "$AGENT_OUT" ]; then
                while IFS= read -r line; do
                    echo -e "    ${{DIM}}Agent: $line${{NC}}"
                done <<< "$AGENT_OUT"
            fi

            if [ -n "$VERIFIER_OUT" ]; then
                echo -e "    ${{DIM}}Verifier: $VERIFIER_OUT${{NC}}"
            fi

            if [ -n "$TRAJECTORY" ]; then
                echo -e "    ${{DIM}}Trajectory: bazel-bin/$TRAJECTORY${{NC}}"
            fi
            echo ""
        fi
    done < "$FAILED_FILE"
fi

echo ""
echo -e "${{BOLD}}Eval Results${{NC}}"
echo "============"
echo ""

# Print header
printf "%-25s %-15s %-25s %s\\n" "TASK" "AGENT" "MODEL" "RESULT"
printf "%-25s %-15s %-25s %s\\n" "----" "-----" "-----" "------"

TOTAL_RUNS=0
TOTAL_PASSED=0
TOTAL_EVALS=0

# Process aggregated results (group by task|agent|model)
sort "$TMPFILE" | while IFS='|' read -r TASK AGENT MODEL PASS_NUM REWARD; do
    echo "$TASK|$AGENT|$MODEL|$PASS_NUM|$REWARD"
done | awk -F'|' '
BEGIN {{
    prev_key = ""
    runs = 0
    passed = 0
    total_reward = 0
}}
{{
    key = $1 "|" $2 "|" $3
    if (key != prev_key && prev_key != "") {{
        print prev_key "|" passed "|" runs "|" total_reward
        runs = 0
        passed = 0
        total_reward = 0
    }}
    prev_key = key
    runs++
    passed += $4
    total_reward += $5
}}
END {{
    if (prev_key != "") {{
        print prev_key "|" passed "|" runs "|" total_reward
    }}
}}
' | while IFS='|' read -r TASK AGENT MODEL PASSED RUNS REWARD; do
    TOTAL_RUNS=$((TOTAL_RUNS + RUNS))
    TOTAL_PASSED=$((TOTAL_PASSED + PASSED))
    TOTAL_EVALS=$((TOTAL_EVALS + 1))

    # Truncate model name for display
    MODEL_SHORT=$(echo "$MODEL" | sed 's/claude-//' | cut -c1-22)

    # Calculate average reward
    AVG_REWARD=$(echo "scale=2; $REWARD / $RUNS" | bc)

    if [ "$PASSED" -eq "$RUNS" ]; then
        if [ "$RUNS" -eq 1 ]; then
            printf "%-25s %-15s %-25s ${{GREEN}}PASS${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$AVG_REWARD"
        else
            printf "%-25s %-15s %-25s ${{GREEN}}%d/%d${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$PASSED" "$RUNS" "$AVG_REWARD"
        fi
    elif [ "$PASSED" -eq 0 ]; then
        if [ "$RUNS" -eq 1 ]; then
            printf "%-25s %-15s %-25s ${{RED}}FAIL${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$AVG_REWARD"
        else
            printf "%-25s %-15s %-25s ${{RED}}%d/%d${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$PASSED" "$RUNS" "$AVG_REWARD"
        fi
    else
        printf "%-25s %-15s %-25s ${{YELLOW}}%d/%d${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$PASSED" "$RUNS" "$AVG_REWARD"
    fi

    # Write totals to file for summary
    echo "$TOTAL_RUNS $TOTAL_PASSED $TOTAL_EVALS" > "$TMPFILE.totals"
done

echo ""
echo "============"

# Read totals (handle case where no results)
if [ -f "$TMPFILE.totals" ]; then
    read TOTAL_RUNS TOTAL_PASSED TOTAL_EVALS < "$TMPFILE.totals"
else
    TOTAL_RUNS=0
    TOTAL_PASSED=0
    TOTAL_EVALS=0
fi

# Calculate pass rate
if [ "$TOTAL_RUNS" -gt 0 ]; then
    PASS_RATE=$(echo "scale=1; $TOTAL_PASSED * 100 / $TOTAL_RUNS" | bc)
else
    PASS_RATE="0.0"
fi

TOTAL_FAILED=$((TOTAL_RUNS - TOTAL_PASSED))

# Summary with color
echo -e "${{BOLD}}Summary:${{NC}} $TOTAL_EVALS evals, $TOTAL_RUNS runs, ${{GREEN}}$TOTAL_PASSED passed${{NC}}, ${{RED}}$TOTAL_FAILED failed${{NC}} ($PASS_RATE%)"
echo ""

# Exit with failure if any run failed
if [ "$TOTAL_FAILED" -gt 0 ]; then
    exit 1
fi
'''.format(
        manifest_path = manifest.short_path,
    )

    ctx.actions.write(
        output = runner,
        content = script_content,
        is_executable = True,
    )

    # Collect runfiles
    runfiles = ctx.runfiles(files = result_files + [manifest])

    return [
        DefaultInfo(
            executable = runner,
            runfiles = runfiles,
            files = depset(result_files),
        ),
    ]

_eval_suite = rule(
    implementation = _eval_suite_impl,
    doc = "Aggregates eval_run results and displays them. Run with `bazel run`.",
    executable = True,
    attrs = {
        "runs": attr.label_list(
            doc = "List of eval_run targets to aggregate.",
            providers = [EvalResultInfo],
            mandatory = True,
        ),
    },
)

def eval_suite(name, runs, **kwargs):
    """Creates an executable that aggregates and displays eval results.

    Run with `bazel run` to see a formatted table of results.

    Args:
        name: Name of the suite target.
        runs: List of eval_run target labels to aggregate.
        **kwargs: Additional arguments passed to the underlying rule.

    Example:
        eval_suite(
            name = "my_suite",
            runs = [
                ":hello_world_claude",
                ":hello_world_opus",
            ],
        )
    """
    _eval_suite(
        name = name,
        runs = runs,
        **kwargs
    )

"""eval_suite rule - executable that aggregates and displays eval results."""

load(":providers.bzl", "EvalResultInfo")

def _eval_suite_impl(ctx):
    """Implementation of eval_suite rule."""

    # Collect all result JSON files from eval_run targets
    result_files = []
    for run in ctx.attr.runs:
        if EvalResultInfo in run:
            result_files.append(run[EvalResultInfo].result_json)

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
NC='\\033[0m' # No Color
BOLD='\\033[1m'

echo ""
echo -e "${{BOLD}}Eval Results${{NC}}"
echo "============"
echo ""

# Print header
printf "%-30s %-20s %-30s %s\\n" "TASK" "AGENT" "MODEL" "RESULT"
printf "%-30s %-20s %-30s %s\\n" "----" "-----" "-----" "------"

TOTAL=0
PASSED=0
FAILED=0

# Read each result file and print
while IFS= read -r result_file; do
    if [ -n "$result_file" ] && [ -f "$result_file" ]; then
        TOTAL=$((TOTAL + 1))

        # Parse JSON (simple grep-based parsing)
        TASK=$(grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        AGENT=$(grep -o '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        MODEL=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$result_file" | sed 's/.*"\\([^"]*\\)"$/\\1/')
        PASS=$(grep -o '"passed"[[:space:]]*:[[:space:]]*[a-z]*' "$result_file" | sed 's/.*:[[:space:]]*//')
        REWARD=$(grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.]*' "$result_file" | sed 's/.*:[[:space:]]*//')

        # Truncate model name for display
        MODEL_SHORT=$(echo "$MODEL" | sed 's/claude-//' | cut -c1-25)

        if [ "$PASS" = "true" ]; then
            PASSED=$((PASSED + 1))
            printf "%-30s %-20s %-30s ${{GREEN}}PASS${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$REWARD"
        else
            FAILED=$((FAILED + 1))
            printf "%-30s %-20s %-30s ${{RED}}FAIL${{NC}} (%.2f)\\n" "$TASK" "$AGENT" "$MODEL_SHORT" "$REWARD"
        fi
    fi
done < "$MANIFEST"

echo ""
echo "============"

# Calculate pass rate
if [ $TOTAL -gt 0 ]; then
    PASS_RATE=$(echo "scale=1; $PASSED * 100 / $TOTAL" | bc)
else
    PASS_RATE="0.0"
fi

# Summary with color
echo -e "${{BOLD}}Summary:${{NC}} $TOTAL evals, ${{GREEN}}$PASSED passed${{NC}}, ${{RED}}$FAILED failed${{NC}} ($PASS_RATE%)"
echo ""

# Exit with failure if any eval failed
if [ $FAILED -gt 0 ]; then
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

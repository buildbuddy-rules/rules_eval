"""eval_task rule - defines an evaluation task."""

load(":providers.bzl", "TaskInfo")

def _eval_task_impl(ctx):
    """Implementation of eval_task rule."""

    # Collect all environment files
    environment_files = depset(
        direct = ctx.files.environment,
    )

    # Collect all test files
    test_files = depset(
        direct = ctx.files.tests,
    )

    # Solution files (optional, for oracle agent)
    solution_files = depset(ctx.files.solution) if ctx.files.solution else depset()

    # Build metadata dict
    metadata = {
        "difficulty": ctx.attr.difficulty,
        "category": ctx.attr.category,
        "task_tags": ctx.attr.task_tags,
    }

    return [
        TaskInfo(
            name = ctx.label.name,
            instruction = ctx.file.instruction,
            config = ctx.file.config if ctx.file.config else None,
            environment_files = environment_files,
            test_files = test_files,
            solution_files = solution_files,
            timeout_secs = ctx.attr.agent_timeout_secs,
            verifier_timeout_secs = ctx.attr.verifier_timeout_secs,
            metadata = metadata,
        ),
        DefaultInfo(
            files = depset(
                [ctx.file.instruction] +
                ([ctx.file.config] if ctx.file.config else []),
            ),
            runfiles = ctx.runfiles(
                files = ctx.files.environment + ctx.files.tests + ctx.files.solution,
            ),
        ),
    ]

eval_task = rule(
    implementation = _eval_task_impl,
    doc = "Defines an evaluation task with instruction, environment, and tests.",
    attrs = {
        "instruction": attr.label(
            doc = "The instruction.md file containing the task description for the agent.",
            allow_single_file = [".md", ".txt"],
            mandatory = True,
        ),
        "config": attr.label(
            doc = "The task.toml configuration file (optional).",
            allow_single_file = [".toml"],
        ),
        "environment": attr.label_list(
            doc = "Files that make up the task environment (initial state).",
            allow_files = True,
            default = [],
        ),
        "tests": attr.label_list(
            doc = "Test/verification files (test.sh, test_*.py, etc.).",
            allow_files = True,
            default = [],
        ),
        "solution": attr.label_list(
            doc = "Solution files for oracle agent (optional).",
            allow_files = True,
            default = [],
        ),
        "agent_timeout_secs": attr.int(
            doc = "Timeout for agent execution in seconds.",
            default = 300,
        ),
        "verifier_timeout_secs": attr.int(
            doc = "Timeout for verification in seconds.",
            default = 120,
        ),
        "difficulty": attr.string(
            doc = "Task difficulty level.",
            default = "medium",
            values = ["easy", "medium", "hard", "expert"],
        ),
        "category": attr.string(
            doc = "Task category.",
            default = "general",
        ),
        "task_tags": attr.string_list(
            doc = "Task tags for filtering.",
            default = [],
        ),
    },
)

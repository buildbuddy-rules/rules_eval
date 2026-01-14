"""Macros for creating evaluation test suites."""

load("//eval/eval:eval_run.bzl", "eval_run")

def eval_suite(name, tests, **kwargs):
    """Creates a test_suite grouping multiple eval_run targets.

    Args:
        name: Name of the test suite.
        tests: List of eval_run target labels to include.
        **kwargs: Additional arguments passed to native.test_suite.
    """
    native.test_suite(
        name = name,
        tests = tests,
        **kwargs
    )

def eval_matrix(
        name,
        tasks,
        agents,
        models = None,
        tags = None,
        visibility = None,
        **kwargs):
    """Creates eval_run targets for all combinations of tasks, agents, and models.

    This macro generates a Cartesian product of eval_run targets and groups
    them into a test_suite.

    Args:
        name: Base name for generated targets. Individual targets will be
              named {name}_{task}_{agent}[_{model}].
        tasks: List of eval_task labels.
        agents: List of eval_agent labels.
        models: Optional list of model identifiers. If None, uses agent defaults.
        tags: Tags to apply to all generated eval_run targets.
        visibility: Visibility for all generated targets.
        **kwargs: Additional arguments passed to each eval_run.

    Example:
        eval_matrix(
            name = "full_eval",
            tasks = [
                "//tasks:hello_world",
                "//tasks:fix_bug",
            ],
            agents = [
                "//agents:claude_code",
                "//agents:openhands",
            ],
            models = [
                "claude-sonnet-4-20250514",
                "claude-opus-4-20250514",
            ],
        )

        # Creates targets:
        #   :full_eval_hello_world_claude_code_claude_sonnet_4_20250514
        #   :full_eval_hello_world_claude_code_claude_opus_4_20250514
        #   :full_eval_hello_world_openhands_claude_sonnet_4_20250514
        #   ...
        # And a test_suite: :full_eval
    """
    runs = []
    all_tags = tags if tags else []

    for task in tasks:
        # Extract task name from label
        task_name = _extract_name(task)

        for agent in agents:
            # Extract agent name from label
            agent_name = _extract_name(agent)

            if models:
                for model in models:
                    # Sanitize model name for target name
                    model_short = _sanitize_name(model)
                    run_name = "{}_{}_{}_{}".format(name, task_name, agent_name, model_short)

                    eval_run(
                        name = run_name,
                        task = task,
                        agent = agent,
                        model = model,
                        tags = all_tags + ["eval", agent_name, model_short],
                        visibility = visibility,
                        **kwargs
                    )
                    runs.append(":" + run_name)
            else:
                run_name = "{}_{}_{}".format(name, task_name, agent_name)

                eval_run(
                    name = run_name,
                    task = task,
                    agent = agent,
                    tags = all_tags + ["eval", agent_name],
                    visibility = visibility,
                    **kwargs
                )
                runs.append(":" + run_name)

    # Create the test suite
    eval_suite(
        name = name,
        tests = runs,
        visibility = visibility,
    )

def _extract_name(label):
    """Extract the target name from a label string."""
    if ":" in label:
        return label.split(":")[-1]
    return label.split("/")[-1]

def _sanitize_name(s):
    """Sanitize a string for use in a Bazel target name."""
    result = ""
    for c in s.elems():
        if c.isalnum():
            result += c
        elif c in ["-", "_", "."]:
            result += "_"
    return result

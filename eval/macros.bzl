"""Macros for creating evaluation suites."""

load("//eval/eval:eval_run.bzl", "eval_run")
load("//eval/eval:eval_suite.bzl", "eval_suite")

def eval_matrix(
        name,
        tasks,
        agents,
        models = None,
        visibility = None,
        **kwargs):
    """Creates eval_run targets for all combinations of tasks, agents, and models.

    This macro generates a Cartesian product of eval_run targets and groups
    them into an eval_suite that can be run with `bazel run`.

    Args:
        name: Base name for generated targets. Individual targets will be
              named {name}_{task}_{agent}[_{model}].
        tasks: List of eval_task labels.
        agents: List of eval_agent labels.
        models: Optional list of model identifiers. If None, uses agent defaults.
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
        #   ...
        # And an eval_suite: :full_eval (run with `bazel run :full_eval`)
    """
    runs = []

    for task in tasks:
        task_name = _extract_name(task)

        for agent in agents:
            agent_name = _extract_name(agent)

            if models:
                for model in models:
                    model_short = _sanitize_name(model)
                    run_name = "{}_{}_{}_{}".format(name, task_name, agent_name, model_short)

                    eval_run(
                        name = run_name,
                        task = task,
                        agent = agent,
                        model = model,
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
                    visibility = visibility,
                    **kwargs
                )
                runs.append(":" + run_name)

    # Create the eval suite
    eval_suite(
        name = name,
        runs = runs,
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

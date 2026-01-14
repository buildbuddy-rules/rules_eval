"""Providers for evaluation results."""

EvalResultInfo = provider(
    doc = "Results from an evaluation run.",
    fields = {
        "task_label": "Label of the task that was evaluated",
        "agent_label": "Label of the agent used",
        "model": "Model identifier used for the run",
        "result_json": "File containing structured results",
    },
)

"""Providers for evaluation tasks."""

TaskInfo = provider(
    doc = "Information about an evaluation task.",
    fields = {
        "name": "Task name/identifier",
        "instruction": "File containing the task instruction (instruction.md)",
        "config": "File containing task configuration (task.toml)",
        "environment_files": "Depset of files for the task environment",
        "test_files": "Depset of test/verification files",
        "solution_files": "Depset of solution files (optional, for oracle agent)",
        "timeout_secs": "Agent timeout in seconds",
        "verifier_timeout_secs": "Verifier timeout in seconds",
        "metadata": "Dict of task metadata (difficulty, category, tags)",
    },
)

DatasetInfo = provider(
    doc = "Information about a dataset (collection of tasks).",
    fields = {
        "name": "Dataset name",
        "version": "Dataset version string",
        "tasks": "List of TaskInfo providers",
        "manifest": "File containing dataset manifest JSON",
    },
)

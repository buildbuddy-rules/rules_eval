# rules_eval

Bazel rules for evaluating AI coding agents on structured tasks.

## Overview

`rules_eval` provides a framework for systematically benchmarking AI agents against reproducible tasks. It includes:

- **Task definitions** with instructions, test files, and optional solutions
- **Pluggable agents** (Claude Code, Codex, custom binaries)
- **Evaluation execution** with configurable timeouts and models
- **Result aggregation** across multiple evaluations

All evaluations benefit from Bazel's caching and parallelization.

## Setup

### 1. Add the module dependency

Add the dependency to your `MODULE.bazel` using `git_override`:

```starlark
bazel_dep(name = "rules_eval", version = "0.0.0")
git_override(
    module_name = "rules_eval",
    remote = "https://github.com/anthropics/rules_eval.git",
    commit = "4375459acd5f568a1be48164e94ec375d66b791c",
)
```

### 2. Configure API keys

Create a `user.bazelrc` file in your repository root:

```
common --action_env=ANTHROPIC_API_KEY=your-anthropic-api-key
common --action_env=OPENAI_API_KEY=your-openai-api-key
```

Add `user.bazelrc` to your `.gitignore` to avoid committing secrets.

### 3. Import the rules

In your `BUILD.bazel` files:

```starlark
load("@rules_eval//eval:defs.bzl", "eval_task", "eval_run", "eval_suite", "eval_matrix")
load("@rules_eval//eval:defs.bzl", "claude_code_agent", "codex_agent", "oracle_agent", "binary_agent")
```

## Concepts

### Tasks

A task defines what the agent should accomplish:

- **instruction**: A markdown or text file describing what the agent should do
- **tests**: Verification scripts (typically `test.sh`) that check if the task was completed
- **solution**: Optional known-good solution for the oracle agent
- **environment**: Optional initial state files to copy into the workdir

### Agents

An agent is an executable that attempts to complete tasks. Agents receive:

- An instruction file
- A working directory
- An output directory
- A timeout value
- An optional model override

### Evaluations

An evaluation runs an agent on a task and captures the results, including:

- Pass/fail status
- Reward value (from test output or `reward.txt`)
- Agent output and trajectory
- Verifier output

## Usage

### Defining a task

```starlark
eval_task(
    name = "hello_world",
    instruction = "instruction.md",
    tests = glob(["tests/**"]),
    solution = glob(["solution/**"]),
    difficulty = "easy",
    category = "file-io",
)
```

The `instruction.md` describes what the agent should do:

```markdown
Create a file called `hello.txt` containing the text "Hello, World!".
```

The `tests/test.sh` verifies completion:

```bash
#!/bin/bash
if grep -q "Hello, World!" hello.txt; then
    echo "PASS"
    exit 0
else
    echo "FAIL: hello.txt missing or has wrong content"
    exit 1
fi
```

### Defining agents

**Using built-in agents:**

```starlark
load("@rules_eval//eval:defs.bzl", "claude_code_agent", "codex_agent", "oracle_agent")

claude_code_agent(name = "claude")
codex_agent(name = "codex")
oracle_agent(name = "oracle")
```

**Wrapping a custom binary:**

```starlark
load("@rules_eval//eval:defs.bzl", "binary_agent")

binary_agent(
    name = "my_agent",
    binary = ":my_agent_bin",
    default_model = "gpt-4",
    invocation = "{binary} --model {model} --prompt {instruction}",
)
```

The `invocation` template supports these placeholders:

| Placeholder | Description |
|-------------|-------------|
| `{binary}` | Path to the executable |
| `{instruction}` | Instruction content (shell-quoted) |
| `{instruction_file}` | Path to the instruction file |
| `{model}` | Model name |

### Running evaluations

**Single evaluation:**

```starlark
eval_run(
    name = "hello_world_claude",
    task = "//tasks:hello_world",
    agent = "//agents:claude",
)
```

```bash
bazel run //examples:hello_world_claude
```

**Evaluation suite:**

```starlark
eval_suite(
    name = "hello_world_all",
    runs = [
        ":hello_world_oracle",
        ":hello_world_claude",
        ":hello_world_codex",
    ],
)
```

```bash
bazel run //examples:hello_world_all
```

**Matrix evaluation (Cartesian product):**

```starlark
eval_matrix(
    name = "full_eval",
    tasks = [
        "//tasks:hello_world",
        "//tasks:fix_bug",
    ],
    agents = [
        "//agents:claude",
        "//agents:codex",
    ],
    models = [
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
    ],
)
```

This creates individual `eval_run` targets for each combination and groups them into a suite.

### Multiple runs

Run evaluations multiple times to measure consistency:

```bash
# Override run count at build time
bazel run //examples:hello_world_claude --//flag:run_count=5
```

Or set it in the BUILD file:

```starlark
eval_run(
    name = "hello_world_claude",
    task = "//tasks:hello_world",
    agent = "//agents:claude",
    run_count = 5,
)
```

Results are cached per-run, so increasing the count only executes new runs.

## Built-in Agents

| Agent | Description | Required Environment |
|-------|-------------|---------------------|
| `claude_code_agent` | Anthropic's Claude Code CLI | `ANTHROPIC_API_KEY` |
| `codex_agent` | OpenAI's Codex CLI | `OPENAI_API_KEY` |
| `oracle_agent` | Runs the task's known solution | None |
| `nop_agent` | No-op agent for testing infrastructure | None |
| `binary_agent` | Generic wrapper for custom executables | Configurable |

## Task Configuration

```starlark
eval_task(
    name = "my_task",
    instruction = "instruction.md",
    tests = glob(["tests/**"]),
    solution = glob(["solution/**"]),
    environment = glob(["env/**"]),
    config = "config.toml",
    difficulty = "medium",  # easy, medium, hard, expert
    category = "debugging",
    task_tags = ["python", "async"],
    agent_timeout = 600,    # seconds (default: 300)
    verifier_timeout = 120, # seconds (default: 120)
)
```

## Output Format

Each evaluation produces a JSON result:

```json
{
  "task": "hello_world",
  "agent": "claude-code",
  "model": "claude-sonnet-4-20250514",
  "run": 1,
  "reward": 1.0,
  "passed": true,
  "trajectory": "bazel-bin/examples/hello_world_claude_run_1_trajectory.txt",
  "agent_output": "...",
  "verifier_output": "PASS"
}
```

The suite runner displays formatted results with pass/fail indicators and aggregated statistics.

## Project Structure

```
eval/
├── defs.bzl              # Public API
├── macros.bzl            # eval_matrix macro
├── agent/
│   ├── agent.bzl         # eval_agent rule
│   └── builtin/          # Built-in agent implementations
├── task/
│   └── task.bzl          # eval_task rule
└── eval/
    ├── eval_run.bzl      # eval_run rule
    └── eval_suite.bzl    # eval_suite macro
```

## Examples

See the `examples/` directory for complete working examples:

```bash
# Run the hello world task with the oracle agent (should always pass)
bazel run //examples:hello_world_oracle

# Run with Claude Code
bazel run //examples:hello_world_claude

# Run the full evaluation suite
bazel run //examples:hello_world_all
```

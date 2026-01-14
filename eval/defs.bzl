"""Public API for rules_eval.

This file exports all public rules and macros for agent evaluation.

Example usage in a BUILD file:

    load("@rules_eval//eval:defs.bzl", "eval_task", "eval_agent", "eval_run")

    eval_task(
        name = "my_task",
        instruction = "instruction.md",
        tests = glob(["tests/**"]),
    )

    eval_run(
        name = "my_eval",
        task = ":my_task",
        agent = "//agents:claude_code",
    )
"""

# Task rules
load("//eval/task:task.bzl", _eval_task = "eval_task")
load("//eval/task:providers.bzl", _DatasetInfo = "DatasetInfo", _TaskInfo = "TaskInfo")

# Agent rules
load("//eval/agent:agent.bzl", _eval_agent = "eval_agent")
load("//eval/agent:providers.bzl", _AgentInfo = "AgentInfo")

# Eval rules
load("//eval/eval:eval_run.bzl", _eval_run = "eval_run")
load("//eval/eval:providers.bzl", _EvalResultInfo = "EvalResultInfo")

# Macros
load("//eval:macros.bzl", _eval_matrix = "eval_matrix", _eval_suite = "eval_suite")

# Built-in agents
load("//eval/agent/builtin:nop.bzl", _nop_agent = "nop_agent")
load("//eval/agent/builtin:claude_code.bzl", _claude_code_agent = "claude_code_agent")

# Re-export rules
eval_task = _eval_task
eval_agent = _eval_agent
eval_run = _eval_run

# Re-export macros
eval_matrix = _eval_matrix
eval_suite = _eval_suite

# Re-export built-in agents
nop_agent = _nop_agent
claude_code_agent = _claude_code_agent

# Re-export providers
TaskInfo = _TaskInfo
DatasetInfo = _DatasetInfo
AgentInfo = _AgentInfo
EvalResultInfo = _EvalResultInfo

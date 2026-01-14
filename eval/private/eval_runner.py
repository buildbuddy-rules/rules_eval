#!/usr/bin/env python3
"""Evaluation runner script for agent evals.

This script orchestrates agent execution and verification. It's designed
to run inside RBE workers as part of the eval_run test target.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Run an agent evaluation")
    parser.add_argument("--instruction", required=True, help="Path to instruction file")
    parser.add_argument("--workdir", required=True, help="Working directory for agent")
    parser.add_argument("--output", required=True, help="Output directory for results")
    parser.add_argument("--timeout", type=int, default=300, help="Agent timeout in seconds")
    parser.add_argument("--model", default="", help="Model to use")
    return parser.parse_args()


def main():
    args = parse_args()

    # Ensure output directory exists
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Read instruction
    instruction_path = Path(args.instruction)
    if not instruction_path.exists():
        print(f"Error: Instruction file not found: {instruction_path}", file=sys.stderr)
        sys.exit(1)

    instruction = instruction_path.read_text()

    # Log configuration
    print(f"Evaluation Runner")
    print(f"  Instruction: {args.instruction}")
    print(f"  Workdir: {args.workdir}")
    print(f"  Output: {args.output}")
    print(f"  Timeout: {args.timeout}s")
    print(f"  Model: {args.model or '(default)'}")
    print()

    # This is a placeholder - actual agent execution happens in the shell wrapper
    # This script can be extended for more complex orchestration

    result = {
        "status": "ready",
        "instruction_length": len(instruction),
        "model": args.model,
    }

    result_path = output_dir / "runner_info.json"
    result_path.write_text(json.dumps(result, indent=2))

    print(f"Runner info written to: {result_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

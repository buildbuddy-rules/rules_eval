#!/usr/bin/env python3
"""Aggregator script for collecting and computing metrics from eval results.

Reads result JSON files from multiple eval runs and computes aggregate metrics.
"""

import argparse
import json
import sys
from pathlib import Path
from collections import defaultdict
from statistics import mean, median, stdev


def parse_args():
    parser = argparse.ArgumentParser(description="Aggregate evaluation results")
    parser.add_argument("--results", nargs="+", required=True, help="Result JSON files")
    parser.add_argument("--output-metrics", required=True, help="Output metrics JSON")
    parser.add_argument("--output-summary", required=True, help="Output summary JSON")
    parser.add_argument("--group-by", default="agent", help="Field to group by")
    parser.add_argument("--metrics", nargs="+", default=["pass_rate", "mean_reward"],
                       help="Metrics to compute")
    return parser.parse_args()


def load_results(result_files):
    """Load result JSON files."""
    results = []
    for path in result_files:
        try:
            with open(path) as f:
                results.append(json.load(f))
        except (json.JSONDecodeError, FileNotFoundError) as e:
            print(f"Warning: Could not load {path}: {e}", file=sys.stderr)
    return results


def compute_metrics(results, metrics_list):
    """Compute aggregate metrics from results."""
    if not results:
        return {}

    rewards = [r.get("reward", 0) for r in results]
    passed = sum(1 for r in rewards if r >= 1.0)

    computed = {}

    if "pass_rate" in metrics_list:
        computed["pass_rate"] = passed / len(results) if results else 0

    if "mean_reward" in metrics_list:
        computed["mean_reward"] = mean(rewards) if rewards else 0

    if "median_reward" in metrics_list:
        computed["median_reward"] = median(rewards) if rewards else 0

    if "std_reward" in metrics_list and len(rewards) > 1:
        computed["std_reward"] = stdev(rewards)

    computed["total"] = len(results)
    computed["passed"] = passed
    computed["failed"] = len(results) - passed

    return computed


def group_results(results, group_by):
    """Group results by a field."""
    groups = defaultdict(list)
    for r in results:
        key = r.get(group_by, "unknown")
        groups[key].append(r)
    return dict(groups)


def main():
    args = parse_args()

    # Load all results
    results = load_results(args.results)

    if not results:
        print("No valid results found", file=sys.stderr)
        sys.exit(1)

    # Group results
    grouped = group_results(results, args.group_by)

    # Compute metrics per group
    group_metrics = {}
    for group_name, group_results in grouped.items():
        group_metrics[group_name] = compute_metrics(group_results, args.metrics)

    # Compute overall metrics
    overall = compute_metrics(results, args.metrics)

    # Build output
    metrics_output = {
        "groups": group_metrics,
        "overall": overall,
        "group_by": args.group_by,
        "total_results": len(results),
    }

    summary_output = {
        "pass_rate": overall.get("pass_rate", 0),
        "mean_reward": overall.get("mean_reward", 0),
        "total": overall.get("total", 0),
        "passed": overall.get("passed", 0),
        "failed": overall.get("failed", 0),
    }

    # Write outputs
    Path(args.output_metrics).write_text(json.dumps(metrics_output, indent=2))
    Path(args.output_summary).write_text(json.dumps(summary_output, indent=2))

    print(f"Aggregated {len(results)} results")
    print(f"  Pass rate: {overall.get('pass_rate', 0):.1%}")
    print(f"  Mean reward: {overall.get('mean_reward', 0):.3f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

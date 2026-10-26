#!/usr/bin/env python3
"""Times the operations that change a world across world sizes, to see how
their cost grows.

Running an operation on each of N entities takes time proportional to N if the
operation is amortized constant (the lists are updated in place), and to N
squared if each one copies the world. So the number to watch is how the total
changes when N doubles: about 2x for in-place, about 4x for copying.

    python3 bench/scaling.py
    python3 bench/scaling.py despawn insert --start 2000 --budget 20 --opt dev

The workloads are in bench/ops.roc, which is built once and run with each
operation and size as its arguments. Every workload first spawns its N
entities, so the time `spawn` takes for the same N is subtracted from the
others, and a run that spawns nothing is subtracted from `spawn`. What is left
is the operation alone.
"""

import argparse
import math
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BENCH = Path(__file__).resolve().parent
WORKLOAD = BENCH / "ops.roc"
OPS = ["spawn", "despawn", "churn", "replace", "insert", "take", "get", "map", "map_in", "map1", "map2"]


def build(scratch, opt):
    binary = Path(scratch) / "ops"
    result = subprocess.run(["roc", "build", str(WORKLOAD), f"--opt={opt}", f"--output={binary}"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"roc build failed:\n{result.stdout}{result.stderr}")
    return binary


def run_once(binary, op, entities):
    started = time.perf_counter()
    result = subprocess.run([str(binary), op, str(entities)], capture_output=True, text=True)
    elapsed = time.perf_counter() - started
    if result.returncode != 0 or result.stdout.strip() != f"{op} {entities}":
        sys.exit(f"the {op} workload failed for {entities} entities:\n{result.stdout}{result.stderr}")
    return elapsed


def measure(binary, op, entities, runs):
    """Fastest of `runs`: the noise here only ever adds time."""
    return min(run_once(binary, op, entities) for _ in range(runs))


def exponent_of(points):
    """Slope of log(time) against log(entities), by least squares."""
    xs = [math.log(n) for n, _ in points]
    ys = [math.log(t) for _, t in points]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)


def verdict(points):
    if len(points) < 2:
        return None, "not enough sizes rose above the noise; raise --max or --budget"
    exponent = exponent_of(points)
    if exponent < 1.3:
        return exponent, "amortized constant: updated in place"
    if exponent > 1.7:
        return exponent, "grows with the world: something is copied every time"
    return exponent, "in between; widen the range (--max, --budget) to tell"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ops", nargs="*", metavar="op", help=f"which operations to time (default all): {', '.join(OPS)}")
    parser.add_argument("--start", type=int, default=1000, help="smallest world (default 1000)")
    parser.add_argument("--max", type=int, default=1_024_000, help="largest world (default 1024000)")
    parser.add_argument("--budget", type=float, default=2.0, help="stop doubling once a run takes this many seconds (default 2)")
    parser.add_argument("--runs", type=int, default=3, help="runs per size, fastest kept (default 3)")
    parser.add_argument("--opt", default="speed", help="roc --opt mode (default speed)")
    args = parser.parse_args()

    ops = args.ops or OPS
    unknown = [op for op in ops if op not in OPS]
    if unknown:
        parser.error(f"unknown operation {', '.join(unknown)}; choose from {', '.join(OPS)}")

    with tempfile.TemporaryDirectory() as scratch:
        binary = build(scratch, args.opt)
        # Many runs: every `spawn` row has this subtracted from it.
        startups = sorted(run_once(binary, "spawn", 0) for _ in range(args.runs * 5))
        startup = startups[0]
        # Differences smaller than the baseline's own spread mean nothing.
        noise = max(startups[len(startups) // 2] - startup, 0.001)
        print(f"startup: {startup * 1000:.1f}ms, noise about {noise * 1000:.1f}ms (--opt={args.opt})")

        # Whole-run time of `spawn` per size: the setup the other workloads share.
        spawning = {}

        def setup(entities):
            if entities not in spawning:
                spawning[entities] = measure(binary, "spawn", entities, args.runs)
            return spawning[entities]

        summary = []
        for op in ops:
            print(f"\n{op}\n{'entities':>10}  {'time':>10}  {'per entity':>10}  {'vs half':>8}")
            points = []
            previous = None
            entities = args.start
            while entities <= args.max:
                whole = setup(entities) if op == "spawn" else measure(binary, op, entities, args.runs)
                spent = whole - (startup if op == "spawn" else setup(entities))
                if spent > 3 * noise:
                    each = f"{spent / entities * 1e9:.0f}ns"
                    growth = f"{spent / previous:.1f}x" if previous else ""
                    points.append((entities, spent))
                    previous = spent
                else:
                    each, growth, previous = "(noise)", "", None
                print(f"{entities:>10}  {spent * 1000:>8.1f}ms  {each:>10}  {growth:>8}", flush=True)
                if whole > args.budget:
                    break
                entities *= 2
            exponent, reading = verdict(points)
            last = f"{points[-1][1] / points[-1][0] * 1e9:.0f}ns" if points else ""
            summary.append((op, "" if exponent is None else f"{exponent:.2f}", last, reading))

    print(f"\n{'op':>8}  {'time ~ n^':>9}  {'per entity':>10}")
    for op, exponent, last, reading in summary:
        print(f"{op:>8}  {exponent:>9}  {last:>10}  {reading}")


if __name__ == "__main__":
    main()

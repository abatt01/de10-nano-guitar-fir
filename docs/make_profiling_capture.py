#!/usr/bin/env python3
"""Create timing tables and PNG captures from RTL or board profiling logs."""
import argparse
from pathlib import Path
import re
from statistics import median

from PIL import Image, ImageDraw, ImageFont

DOCS = Path(__file__).resolve().parent
CYCLE_ROWS = (
    "Clear history", "DDR read and wait", "MAC and pipeline drain",
    "Load and pack", "DDR write and wait", "Accelerator total",
)
HOST_ROWS = (
    "ARM CPU", "FPGA end-to-end", "Stage input", "Configure registers",
    "Start to IRQ and status", "Copy output",
)


def rows_from(text, rows, pattern):
    return {row: float(re.search(r"^\s*" + row + pattern, text, re.M).group(1))
            for row in rows}


def simulation(path, variants):
    blocks = path.read_text().split("RTL PASS:")[1:]
    profiles = {(int(re.search(r"Taps per clock\s+(\d+)", block).group(1)),
                 bool(re.search(r"Buffered DDR\s+1", block))): block
                for block in reversed(blocks)}
    blocks = [profiles[variant] for variant in variants]
    rows = list(CYCLE_ROWS)
    rows[2] = "MAC and drain"
    return [{name: value for name, value in zip(
        CYCLE_ROWS, rows_from(block, rows, r"\s+(\d+) cycles").values())}
        for block in blocks]


def board(path, variants):
    results = []
    for variant in variants:
        trials = sorted(path.glob(f"{variant}-[1-5].log"))
        if len(trials) != 5:
            raise ValueError(f"five {variant} logs are required")
        parsed = []
        for trial in trials:
            log = trial.read_text()
            if not log.startswith("MATCH (16384 samples"):
                raise ValueError(f"comparison failed in {trial}")
            parsed.append({
                **rows_from(log, HOST_ROWS, r"\s+(\d+\.\d+) ms"),
                **rows_from(log, CYCLE_ROWS, r"\s+(\d+) cycles"),
            })
        results.append({row: median(trial[row] for trial in parsed) for row in parsed[0]})
    return results


def capture(title, lines, filename):
    mono = ImageFont.truetype("DejaVuSansMono.ttf", 19)
    heading = ImageFont.truetype("DejaVuSans-Bold.ttf", 24)
    image = Image.new("RGB", (980, 92 + len(lines) * 29), "#111a2a")
    draw = ImageDraw.Draw(image)
    draw.text((25, 20), title, font=heading, fill="#62dbc5")
    for i, text in enumerate(lines):
        draw.text((25, 63 + i * 29), text, font=mono, fill="#e5edf5")
    image.save(DOCS / filename, optimize=True)


def format_result(rows, results, factor, suffix, lanes):
    labels = [f"{n} taps/clock" if isinstance(n, int) else n for n in lanes]
    header = f"{'Stage':<26}" + "".join(f"{label:>17}" for label in labels)
    return [header, *[
        f"{row:<26}" + "".join(f"{data[row] / factor:>13.3f} {suffix}" for data in results)
        for row in rows
    ]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulation_log", type=Path)
    parser.add_argument("--evidence", type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--multicore", action="store_true")
    group.add_argument("--buffered", action="store_true")
    args = parser.parse_args()
    if args.buffered:
        lanes = ("16 unbuffered", "16 buffered")
        variants = ("wide", "buffered")
        profiles = ((16, False), (16, True))
        prefix = "fir-buffered"
    else:
        lanes = (4, 8, 16) if args.multicore else (1, 4)
        variants = ("parallel", "symmetric", "wide") if args.multicore else ("serial", "parallel")
        profiles = tuple((n, False) for n in lanes)
        prefix = "fir-multicore" if args.multicore else "fir-profiling"
    sim = simulation(args.simulation_log, profiles)
    gain = sim[0]["Accelerator total"] / sim[-1]["Accelerator total"]
    capture("RTL simulation | guitar clip", [
        "All displayed variants matched all 16,384 ARM output samples.",
        *format_result(CYCLE_ROWS, sim, 50000, "ms", lanes),
        *(["Buffered DDR phases overlap arithmetic. Rows do not add."] if args.buffered else []),
        f"Accelerator speedup under the testbench DDR model: {gain:.2f}x",
    ], f"{prefix}-rtl.png")
    if args.evidence:
        measured = board(args.evidence, variants)
        speedup = measured[0]["FPGA end-to-end"] / measured[-1]["FPGA end-to-end"]
        arm_summary = []
        if args.multicore or args.buffered:
            arm_log = (args.evidence / "arm-bench.log").read_text()
            labels = ("Dual-core median", "Dual NEON median") if args.buffered else (
                "Single-core median", "Dual-core median")
            for label in labels:
                timing = re.search(r"^" + label + r"\s+(\d+\.\d+) ms", arm_log, re.M).group(1)
                arm_summary.append(f"ARM {label.lower()}: {timing} ms")
            capture("DE10-Nano | 15 trials on pinned ARM cores",
                    arm_log.splitlines(),
                    "arm-neon-board.png" if args.buffered else "arm-dual-board.png")
        capture("DE10-Nano | median of five matching trials per variant", [
            *arm_summary,
            *format_result(HOST_ROWS, measured, 1, "ms", lanes),
            "",
            *format_result(CYCLE_ROWS, measured, 50000, "ms", lanes),
            *(["Buffered DDR phases overlap arithmetic. Rows do not add."] if args.buffered else []),
            f"FPGA end-to-end speedup: {speedup:.2f}x",
        ], f"{prefix}-board.png")
        for data in measured:
            print(data)
    print(f"RTL accelerator speedup: {gain:.3f}x")


if __name__ == "__main__":
    main()

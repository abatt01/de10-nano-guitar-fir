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


def simulation(path):
    blocks = path.read_text().split("RTL PASS:")[1:]
    if len(blocks) != 2:
        raise ValueError("both passing RTL profiles are required")
    rows = list(CYCLE_ROWS)
    rows[2] = "MAC and drain"
    return [{name: value for name, value in zip(
        CYCLE_ROWS, rows_from(block, rows, r"\s+(\d+) cycles").values())}
        for block in blocks]


def board(path):
    results = []
    for variant in ("serial", "parallel"):
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


def format_result(rows, results, factor, suffix):
    return [
        f"{'Stage':<26} {'1 tap/clock':>17} {'4 taps/clock':>17}",
        *[f"{row:<26} {results[0][row] / factor:>12.3f} {suffix} "
          f"{results[1][row] / factor:>13.3f} {suffix}" for row in rows],
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulation_log", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    sim = simulation(args.simulation_log)
    gain = sim[0]["Accelerator total"] / sim[1]["Accelerator total"]
    capture("RTL simulation | guitar clip", [
        "Both variants matched all 16,384 ARM output samples.",
        *format_result(CYCLE_ROWS, sim, 50000, "ms"),
        f"Accelerator speedup under the testbench DDR model: {gain:.2f}x",
    ], "fir-profiling-rtl.png")
    if args.evidence:
        measured = board(args.evidence)
        speedup = measured[0]["FPGA end-to-end"] / measured[1]["FPGA end-to-end"]
        capture("DE10-Nano | median of five matching trials per variant", [
            *format_result(HOST_ROWS, measured, 1, "ms"),
            "",
            *format_result(CYCLE_ROWS, measured, 50000, "ms"),
            f"FPGA end-to-end speedup: {speedup:.2f}x",
        ], "fir-profiling-board.png")
        for data in measured:
            print(data)
    print(f"RTL accelerator speedup: {gain:.3f}x")


if __name__ == "__main__":
    main()

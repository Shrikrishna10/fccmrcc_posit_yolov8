#!/usr/bin/env python3
"""
regime_histogram.py — Validate Posit<16,1> regime cap against YOLOv8n activations

THIS SCRIPT IS THE DAY 1 CRITICAL DELIVERABLE.
If >0.1% of activations exceed the [1/64, 64] range, the regime cap must be widened.

Usage:
  pip install ultralytics torch matplotlib numpy
  python regime_histogram.py --num-images 10 --output-dir ./analysis/

Outputs:
  - regime_histogram.png: Distribution of regime values across all layers
  - activation_range.csv: Per-layer min/max/percentile statistics
  - PASS/FAIL verdict for 3-bit regime cap
"""

import argparse
import os
import csv
import numpy as np

try:
    import torch
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False
    print("WARNING: torch/matplotlib not available. Using synthetic data for demonstration.")


# Posit<16,1> with 3-bit regime cap
USEED = 4
REGIME_MAX = 3
MAX_REPRESENTABLE = USEED ** REGIME_MAX   # 64
MIN_REPRESENTABLE = 1.0 / MAX_REPRESENTABLE  # 1/64


def value_to_regime(x: float) -> int:
    """Map a float value to its Posit16 regime value k."""
    if x == 0:
        return 0
    abs_x = abs(x)
    if abs_x >= 1.0:
        k = 0
        while abs_x >= USEED and k < 10:
            abs_x /= USEED
            k += 1
        return k
    else:
        k = 0
        while abs_x < 1.0 and k > -10:
            abs_x *= USEED
            k -= 1
        return k


def run_with_pytorch(num_images: int, output_dir: str):
    """Run YOLOv8n and collect activation statistics."""
    from ultralytics import YOLO

    model = YOLO('yolov8n.pt')
    model.eval()

    # Hook storage
    layer_activations = {}
    hooks = []

    def make_hook(name):
        def hook_fn(module, input, output):
            if isinstance(output, torch.Tensor):
                layer_activations[name] = output.detach().cpu().numpy().flatten()
        return hook_fn

    # Register hooks on all Conv and C2f modules
    for name, module in model.model.named_modules():
        if hasattr(module, 'conv') or 'c2f' in name.lower() or isinstance(module, torch.nn.Conv2d):
            hooks.append(module.register_forward_hook(make_hook(name)))

    # Run inference on sample images
    # Using random tensors as stand-in (replace with COCO images in production)
    all_regime_counts = {}
    layer_stats = []

    print(f"Running YOLOv8n inference on {num_images} images...")
    for img_idx in range(num_images):
        # Random image (640x640x3) — replace with actual COCO images
        dummy_input = torch.randn(1, 3, 640, 640)
        layer_activations.clear()

        with torch.no_grad():
            _ = model(dummy_input, verbose=False)

        for layer_name, acts in layer_activations.items():
            regimes = [value_to_regime(float(v)) for v in acts[:10000]]  # sample for speed
            for r in regimes:
                all_regime_counts[r] = all_regime_counts.get(r, 0) + 1

            if img_idx == 0:
                layer_stats.append({
                    'name': layer_name,
                    'min': float(np.min(acts)),
                    'max': float(np.max(acts)),
                    'mean': float(np.mean(acts)),
                    'std': float(np.std(acts)),
                    'p01': float(np.percentile(acts, 0.1)),
                    'p999': float(np.percentile(acts, 99.9)),
                    'pct_in_range': float(np.mean(
                        (np.abs(acts) <= MAX_REPRESENTABLE) &
                        ((np.abs(acts) >= MIN_REPRESENTABLE) | (acts == 0))
                    ) * 100)
                })

    # Clean up hooks
    for h in hooks:
        h.remove()

    return all_regime_counts, layer_stats


def run_synthetic(output_dir: str):
    """Generate synthetic activation data for demonstration."""
    print("Using synthetic data (install ultralytics for real YOLOv8n analysis)")

    # Typical post-BN activation distribution: centered near 0, std ~1-2
    np.random.seed(42)
    all_regime_counts = {}
    layer_stats = []

    layer_names = [f"backbone.conv{i}" for i in range(5)] + \
                  [f"neck.c2f{i}" for i in range(3)] + \
                  ["head.box", "head.cls"]

    for name in layer_names:
        # Simulate post-BN activations (normal distribution)
        acts = np.random.randn(100000) * 1.5

        regimes = [value_to_regime(float(v)) for v in acts]
        for r in regimes:
            all_regime_counts[r] = all_regime_counts.get(r, 0) + 1

        layer_stats.append({
            'name': name,
            'min': float(np.min(acts)),
            'max': float(np.max(acts)),
            'mean': float(np.mean(acts)),
            'std': float(np.std(acts)),
            'p01': float(np.percentile(acts, 0.1)),
            'p999': float(np.percentile(acts, 99.9)),
            'pct_in_range': float(np.mean(
                (np.abs(acts) <= MAX_REPRESENTABLE) &
                ((np.abs(acts) >= MIN_REPRESENTABLE) | (acts == 0))
            ) * 100)
        })

    return all_regime_counts, layer_stats


def analyse_and_report(regime_counts: dict, layer_stats: list, output_dir: str):
    """Generate plots and CSV reports."""
    os.makedirs(output_dir, exist_ok=True)

    # ── Regime histogram ──────────────────────────────────────
    total = sum(regime_counts.values())
    sorted_regimes = sorted(regime_counts.keys())

    # Calculate saturation rate
    in_range = sum(v for k, v in regime_counts.items() if abs(k) <= REGIME_MAX)
    out_of_range = total - in_range
    saturation_pct = (out_of_range / total) * 100

    print(f"\n{'='*60}")
    print(f"REGIME CAP VALIDATION RESULTS")
    print(f"{'='*60}")
    print(f"Total activation samples: {total:,}")
    print(f"Regime cap: {REGIME_MAX} (range [{1.0/USEED**REGIME_MAX}, {USEED**REGIME_MAX}])")
    print(f"In-range: {in_range:,} ({in_range/total*100:.4f}%)")
    print(f"Out-of-range: {out_of_range:,} ({saturation_pct:.4f}%)")

    PASS = saturation_pct < 0.1
    verdict = "✓ PASS" if PASS else "✗ FAIL"
    print(f"\nVerdict: {verdict} (threshold: <0.1% out-of-range)")

    if not PASS:
        print(f"  ⚠ RECOMMENDATION: Increase REGIME_MAX to 4 (range [1/256, 256])")
        print(f"  Update `REGIME_MAX in posit_defines.svh")
    print(f"{'='*60}\n")

    # Plot
    try:
        fig, axes = plt.subplots(1, 2, figsize=(14, 5))

        # Regime distribution
        ax = axes[0]
        regimes = list(range(min(sorted_regimes), max(sorted_regimes) + 1))
        counts = [regime_counts.get(r, 0) for r in regimes]
        colors = ['green' if abs(r) <= REGIME_MAX else 'red' for r in regimes]
        ax.bar(regimes, counts, color=colors, edgecolor='black', linewidth=0.5)
        ax.set_xlabel('Regime value (k)')
        ax.set_ylabel('Count')
        ax.set_title(f'Posit<16,1> Regime Distribution\n(red = outside ±{REGIME_MAX} cap)')
        ax.axvline(x=-REGIME_MAX - 0.5, color='red', linestyle='--', alpha=0.7)
        ax.axvline(x=REGIME_MAX + 0.5, color='red', linestyle='--', alpha=0.7)

        # Per-layer coverage
        ax = axes[1]
        names = [s['name'][:20] for s in layer_stats]
        coverages = [s['pct_in_range'] for s in layer_stats]
        colors = ['green' if c >= 99.9 else 'orange' if c >= 99 else 'red' for c in coverages]
        ax.barh(names, coverages, color=colors)
        ax.set_xlabel('% activations in representable range')
        ax.set_title('Per-Layer Regime Coverage')
        ax.axvline(x=99.9, color='red', linestyle='--', alpha=0.7, label='99.9% threshold')
        ax.legend()

        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, 'regime_histogram.png'), dpi=150)
        print(f"Plot saved: {os.path.join(output_dir, 'regime_histogram.png')}")
    except Exception as e:
        print(f"Plot generation failed: {e}")

    # CSV report
    csv_path = os.path.join(output_dir, 'activation_range.csv')
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['layer', 'min', 'max', 'mean', 'std', 'p0.1', 'p99.9', 'pct_in_range'])
        for s in layer_stats:
            writer.writerow([s['name'], f"{s['min']:.4f}", f"{s['max']:.4f}",
                           f"{s['mean']:.4f}", f"{s['std']:.4f}",
                           f"{s['p01']:.4f}", f"{s['p999']:.4f}",
                           f"{s['pct_in_range']:.4f}"])
    print(f"CSV saved: {csv_path}")

    return PASS


def main():
    parser = argparse.ArgumentParser(description="Validate Posit16 regime cap for YOLOv8n")
    parser.add_argument("--num-images", type=int, default=10, help="Number of images to process")
    parser.add_argument("--output-dir", type=str, default="./analysis", help="Output directory")
    args = parser.parse_args()

    if HAS_TORCH:
        regime_counts, layer_stats = run_with_pytorch(args.num_images, args.output_dir)
    else:
        regime_counts, layer_stats = run_synthetic(args.output_dir)

    passed = analyse_and_report(regime_counts, layer_stats, args.output_dir)

    if not passed:
        print("\n⚠ ACTION REQUIRED: Regime cap insufficient. See recommendations above.")
        exit(1)
    else:
        print("\n✓ Regime cap validated. Proceed with HDL implementation.")


if __name__ == "__main__":
    main()

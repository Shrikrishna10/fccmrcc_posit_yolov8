#!/usr/bin/env python3
"""
weight_convert.py — Convert YOLOv8n float32 weights to Posit16 with BN folding

Batch Normalisation folding:
  W_folded = W * (gamma / sqrt(var + eps))
  b_folded = gamma * (b - mean) / sqrt(var + eps) + beta

This eliminates BN layers entirely — the folded weights go directly into
the Posit16 systolic array. No BN computation needed in hardware.

Usage:
  pip install ultralytics torch numpy
  python weight_convert.py --model yolov8n.pt --output-dir ./weights/

Outputs:
  - Per-layer .hex files for $readmemh loading in simulation
  - Per-layer .bin files for PS DMA loading in hardware
  - layer_table.csv: Layer schedule for PS software
  - weight_stats.csv: Per-layer weight statistics (for debugging)
"""

import argparse
import os
import csv
import struct
import numpy as np
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_golden_vectors import Posit16


def fold_bn_into_conv(conv_weight, conv_bias, bn_weight, bn_bias, bn_mean, bn_var, eps=1e-5):
    """Fold BatchNorm parameters into Conv weight and bias.

    Args:
        conv_weight: [C_out, C_in, H, W] float32
        conv_bias:   [C_out] float32 (or None if no bias)
        bn_weight:   [C_out] gamma
        bn_bias:     [C_out] beta
        bn_mean:     [C_out] running mean
        bn_var:      [C_out] running var
        eps:         BN epsilon

    Returns:
        folded_weight: [C_out, C_in, H, W] float32
        folded_bias:   [C_out] float32
    """
    if conv_bias is None:
        conv_bias = np.zeros(conv_weight.shape[0])

    # Scale factor per output channel
    scale = bn_weight / np.sqrt(bn_var + eps)

    # Fold into conv
    folded_weight = conv_weight * scale.reshape(-1, 1, 1, 1)
    folded_bias = scale * (conv_bias - bn_mean) + bn_bias

    return folded_weight, folded_bias


def float32_to_posit16_array(arr: np.ndarray) -> np.ndarray:
    """Convert a numpy array of float32 values to Posit16 bit patterns."""
    flat = arr.flatten()
    posit_arr = np.array([Posit16.encode(float(v)) for v in flat], dtype=np.uint16)
    return posit_arr


def save_hex_file(posit_arr: np.ndarray, filepath: str):
    """Save Posit16 array as hex file for $readmemh."""
    with open(filepath, 'w') as f:
        f.write(f"// {len(posit_arr)} Posit16 values\n")
        for val in posit_arr:
            f.write(f"{val:04X}\n")


def save_bin_file(posit_arr: np.ndarray, filepath: str):
    """Save Posit16 array as binary file for DMA loading."""
    posit_arr.astype(np.uint16).tofile(filepath)


def _find_bn_params(state: dict, conv_name: str) -> dict | None:
    """Robustly find BatchNorm parameters associated with a Conv layer.
    
    YOLOv8n uses these patterns:
      - model.X.conv → model.X.bn            (standard Conv→BN in backbone/neck)
      - model.X.cvY.Z.conv → model.X.cvY.Z.bn (inside C2f bottleneck)
      - model.22.cv2.0.0  → model.22.cv2.0.1  (detection head, different numbering)
    
    Returns dict with weight/bias/mean/var or None if no BN found.
    """
    # Build candidate BN prefixes
    candidates = []
    
    # Pattern 1: replace trailing '.conv' with '.bn'
    if conv_name.endswith('.conv'):
        candidates.append(conv_name[:-5] + '.bn')
    
    # Pattern 2: parent + '.bn'
    parts = conv_name.rsplit('.', 1)
    if len(parts) == 2:
        candidates.append(parts[0] + '.bn')
    
    # Pattern 3: for numbered layers like model.X.cv2.0.0 → model.X.cv2.0.1
    # (Conv at index 0, BN at index 1 within a Sequential)
    if parts[-1].isdigit():
        idx = int(parts[-1])
        candidates.append(parts[0] + f'.{idx + 1}')
    
    for bn_prefix in candidates:
        # Check ALL four required BN keys exist
        required_keys = [
            f"{bn_prefix}.weight",
            f"{bn_prefix}.bias",
            f"{bn_prefix}.running_mean",
            f"{bn_prefix}.running_var",
        ]
        if all(k in state for k in required_keys):
            return {
                'weight': state[f"{bn_prefix}.weight"].cpu().numpy(),
                'bias': state[f"{bn_prefix}.bias"].cpu().numpy(),
                'mean': state[f"{bn_prefix}.running_mean"].cpu().numpy(),
                'var': state[f"{bn_prefix}.running_var"].cpu().numpy(),
            }
    
    return None


def extract_yolov8n_layers(model_path: str):
    """Extract layer information from YOLOv8n model.

    Returns list of dicts with: name, type, weights, bias, bn_params, config
    """
    try:
        import torch
        from ultralytics import YOLO

        model = YOLO(model_path)
        state = model.model.state_dict()

        layers = []
        layer_idx = 0

        for name, module in model.model.named_modules():
            if isinstance(module, torch.nn.Conv2d):
                layer_info = {
                    'idx': layer_idx,
                    'name': name,
                    'type': 'Conv2d',
                    'kernel_size': module.kernel_size[0],
                    'c_in': module.in_channels,
                    'c_out': module.out_channels,
                    'stride': module.stride[0],
                    'weight': module.weight.detach().cpu().numpy(),
                    'bias': module.bias.detach().cpu().numpy() if module.bias is not None else None,
                    'bn_params': None
                }

                # Robust BN lookup
                bn_params = _find_bn_params(state, name)
                if bn_params is not None:
                    layer_info['bn_params'] = bn_params
                else:
                    print(f"         [INFO] No BN found for {name} — using raw conv weights")

                layers.append(layer_info)
                layer_idx += 1

        return layers

    except ImportError:
        print("WARNING: torch/ultralytics not available. Generating synthetic layer table.")
        return generate_synthetic_layers()


def generate_synthetic_layers():
    """Generate synthetic layer config for testing without PyTorch."""
    # YOLOv8n architecture (approximate)
    configs = [
        # Backbone
        ('backbone.conv0',  'Conv2d', 3, 3, 16, 2),    # P1
        ('backbone.conv1',  'Conv2d', 3, 16, 32, 2),   # P2
        ('backbone.c2f0.0', 'Conv2d', 3, 32, 32, 1),
        ('backbone.c2f0.1', 'Conv2d', 1, 32, 16, 1),
        ('backbone.conv2',  'Conv2d', 3, 32, 64, 2),   # P3
        ('backbone.c2f1.0', 'Conv2d', 3, 64, 64, 1),
        ('backbone.c2f1.1', 'Conv2d', 1, 64, 32, 1),
        ('backbone.conv3',  'Conv2d', 3, 64, 128, 2),  # P4
        ('backbone.c2f2.0', 'Conv2d', 3, 128, 128, 1),
        ('backbone.c2f2.1', 'Conv2d', 1, 128, 64, 1),
        ('backbone.conv4',  'Conv2d', 3, 128, 256, 2), # P5
        ('backbone.c2f3.0', 'Conv2d', 3, 256, 256, 1),
        ('backbone.c2f3.1', 'Conv2d', 1, 256, 128, 1),
        # Neck
        ('neck.upsample0',  'Conv2d', 1, 256, 128, 1),
        ('neck.c2f4.0',     'Conv2d', 3, 256, 128, 1),
        ('neck.upsample1',  'Conv2d', 1, 128, 64, 1),
        ('neck.c2f5.0',     'Conv2d', 3, 128, 64, 1),
        # Head
        ('head.cv2.0',      'Conv2d', 3, 64, 64, 1),
        ('head.cv3.0',      'Conv2d', 1, 64, 80, 1),   # 80 classes
    ]

    layers = []
    for idx, (name, ltype, ks, cin, cout, stride) in enumerate(configs):
        # Random weights for testing
        w = np.random.randn(cout, cin, ks, ks).astype(np.float32) * 0.1
        layers.append({
            'idx': idx,
            'name': name,
            'type': ltype,
            'kernel_size': ks,
            'c_in': cin,
            'c_out': cout,
            'stride': stride,
            'weight': w,
            'bias': np.zeros(cout, dtype=np.float32),
            'bn_params': {
                'weight': np.ones(cout, dtype=np.float32),
                'bias': np.zeros(cout, dtype=np.float32),
                'mean': np.zeros(cout, dtype=np.float32),
                'var': np.ones(cout, dtype=np.float32),
            }
        })
    return layers


def main():
    parser = argparse.ArgumentParser(description="Convert YOLOv8n weights to Posit16")
    parser.add_argument("--model", type=str, default="yolov8n.pt", help="Model path")
    parser.add_argument("--output-dir", type=str, default="./weights", help="Output directory")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # Extract layers
    print(f"Loading model: {args.model}")
    layers = extract_yolov8n_layers(args.model)
    print(f"Found {len(layers)} conv layers")

    # Layer table for PS software
    table_path = os.path.join(args.output_dir, "layer_table.csv")
    stats_path = os.path.join(args.output_dir, "weight_stats.csv")

    with open(table_path, 'w', newline='') as tf, \
         open(stats_path, 'w', newline='') as sf:

        table_writer = csv.writer(tf)
        table_writer.writerow(['idx', 'name', 'type', 'kernel', 'c_in', 'c_out',
                               'stride', 'weight_file', 'bias_file', 'num_weights',
                               'has_bn'])

        stats_writer = csv.writer(sf)
        stats_writer.writerow(['idx', 'name', 'w_min', 'w_max', 'w_mean', 'w_std',
                               'num_saturated', 'pct_saturated'])

        for layer in layers:
            idx = layer['idx']
            name = layer['name']
            has_bn = layer['bn_params'] is not None
            print(f"  [{idx:3d}] {name}: {layer['type']} "
                  f"k={layer['kernel_size']} cin={layer['c_in']} cout={layer['c_out']}"
                  f" {'(+BN)' if has_bn else '(no BN)'}")

            # Fold BN if present
            w = layer['weight']
            b = layer['bias'] if layer['bias'] is not None else np.zeros(w.shape[0])

            if has_bn:
                bn = layer['bn_params']
                w, b = fold_bn_into_conv(w, b, bn['weight'], bn['bias'],
                                         bn['mean'], bn['var'])
                print(f"         BN folded. Weight range: [{w.min():.4f}, {w.max():.4f}]")

            # Convert to Posit16
            w_posit = float32_to_posit16_array(w)
            b_posit = float32_to_posit16_array(b)

            # Check saturation
            w_flat = w.flatten()
            num_saturated = np.sum(np.abs(w_flat) > 64) + np.sum(
                (np.abs(w_flat) > 0) & (np.abs(w_flat) < 1.0/64))
            pct_saturated = num_saturated / len(w_flat) * 100

            # Save files
            w_hex = f"layer{idx:03d}_weight.hex"
            b_hex = f"layer{idx:03d}_bias.hex"
            save_hex_file(w_posit, os.path.join(args.output_dir, w_hex))
            save_hex_file(b_posit, os.path.join(args.output_dir, b_hex))
            save_bin_file(w_posit, os.path.join(args.output_dir, f"layer{idx:03d}_weight.bin"))
            save_bin_file(b_posit, os.path.join(args.output_dir, f"layer{idx:03d}_bias.bin"))

            # Write table entries
            table_writer.writerow([idx, name, layer['type'], layer['kernel_size'],
                                   layer['c_in'], layer['c_out'], layer['stride'],
                                   w_hex, b_hex, len(w_posit), has_bn])

            stats_writer.writerow([idx, name, f"{w.min():.6f}", f"{w.max():.6f}",
                                   f"{w.mean():.6f}", f"{w.std():.6f}",
                                   num_saturated, f"{pct_saturated:.4f}"])

    print(f"\n✓ Weight conversion complete")
    print(f"  Layer table: {table_path}")
    print(f"  Weight stats: {stats_path}")
    print(f"  Weight files: {args.output_dir}/layer*_weight.hex")
    print(f"\n  Load in PS software using layer_table.csv for DMA scheduling")


if __name__ == "__main__":
    main()

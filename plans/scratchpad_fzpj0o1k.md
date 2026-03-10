# Task: Read YOLOv8n_Posit16_25Day_ProjectPlan.xlsx and identify Person B's tasks

## Checklist
- [x] Open Excel file in browser (Opened via GitHub Raw URL in Aspose Viewer)
- [x] Read content and identify Person B's tasks
- [ ] Summarize findings

## Person B (Software + PS) Tasks
- **B1: Weight conversion script (Days 1-2)**: Load weights, fold BN, convert to Posit16, export binary and JSON config.
- **B2: Activation histogram + regime validation (Days 2-4)**: Record histograms, validate Posit16 regime saturation, generate golden test vectors.
- **B3: PYNQ setup + frame capture (Days 3-5)**: Setup PYNQ, verify HDMI, write frame capture/resize code.
- **B4: Posit16 <-> INT16 converter (Days 5-8)**: Python/C implementation, measure error, provide SV for PL boundary.
- **B5: ARM NEON 1x1 conv kernel (Days 7-10)**: NEON intrinsics C kernel, benchmark.
- **B6: End-to-end PS input pipeline (Days 10-13)**: Normalize, DMA transfer, measure latency.
- **B7: Full PS-side layer processing (Days 13-16)**: Integrate kernels, add SiLU, residual add, maxpool, upsample.
- **B8: NMS + display overlay (Days 16-18)**: Score/box decoding, NMS, OpenCV drawing, display output.
- **B9: mAP benchmarking (Days 21-24)**: Full COCO evaluation, performance table, accuracy comparison.

## Files to be created/fixed by Person B
- `weight_convert.py`, `posit16_utils.py`
- `regime_validation.py`
- `capture.py`
- `posit16_int16.py`, `posit16_int16.c`
- `neon_conv1x1.c`, `test_neon_conv.py`
- `ps_pipeline.py`, `dma_utils.py`
- `ps_layers.py`, `layer_scheduler.py`
- `postprocess.py`, `display.py`
- `benchmark.py`

## Notes
- Local file: [c:\Users\pandi\College\Projects\fccmrcc_posit_yolov8\plans\YOLOv8n_Posit16_25Day_ProjectPlan.xlsx](file:///Users/pandi/College/Projects/fccmrcc_posit_yolov8/plans/YOLOv8n_Posit16_25Day_ProjectPlan.xlsx)
- Viewed via Aspose Online Viewer using GitHub Raw link.

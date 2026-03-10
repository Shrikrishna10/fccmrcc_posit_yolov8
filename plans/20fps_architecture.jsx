import { useState } from "react";

const tabs = [
  { id: "math", label: "The Math", icon: "∑" },
  { id: "dsp", label: "DSP Offload", icon: "⚡" },
  { id: "hybrid", label: "Hybrid PE", icon: "⊕" },
  { id: "arm", label: "ARM Co-compute", icon: "⇆" },
  { id: "pipeline", label: "Pipeline Overlap", icon: "▥" },
  { id: "full", label: "Full Architecture", icon: "◈" },
  { id: "code", label: "RTL Changes", icon: "<>" },
  { id: "verdict", label: "20 FPS Verdict", icon: "✓" },
];

const C = {
  bg: "#06080c", card: "#0c1018", border: "#1a2030", accent: "#3b82f6",
  green: "#22c55e", red: "#ef4444", yellow: "#eab308", cyan: "#06b6d4",
  text: "#c8d0dc", dim: "#5a6578", white: "#f0f4fa",
};

const Box = ({ children, border = C.border, pad = 16, mt = 0 }) => (
  <div style={{ background: C.card, border: `1px solid ${border}`, borderRadius: 8, padding: pad, marginTop: mt }}>
    {children}
  </div>
);

const Tag = ({ color, children }) => (
  <span style={{ background: color + "18", color, padding: "2px 8px", borderRadius: 4, fontSize: 11, fontWeight: 600 }}>
    {children}
  </span>
);

const Row = ({ cells, header }) => (
  <tr>
    {cells.map((c, i) => {
      const T = header ? "th" : "td";
      return (
        <T key={i} style={{
          padding: "7px 10px", borderBottom: `1px solid ${C.border}`, textAlign: i === 0 ? "left" : "center",
          fontWeight: header ? 700 : 400, color: header ? C.cyan : C.text, fontSize: 12.5,
          background: header ? C.bg : "transparent", whiteSpace: "nowrap",
        }}>{c}</T>
      );
    })}
  </tr>
);

const Alert = ({ type = "info", children }) => {
  const m = { info: C.accent, warn: C.yellow, crit: C.red, ok: C.green };
  return (
    <div style={{ borderLeft: `3px solid ${m[type]}`, background: m[type] + "08", padding: "10px 14px", margin: "12px 0", borderRadius: "0 6px 6px 0", fontSize: 13, color: C.text, lineHeight: 1.65 }}>
      {children}
    </div>
  );
};

const Code = ({ children }) => (
  <pre style={{ background: "#080c14", border: `1px solid ${C.border}`, borderRadius: 6, padding: 14, fontSize: 11.5, color: "#8ba4c4", fontFamily: "'JetBrains Mono', 'Fira Code', monospace", margin: "10px 0", overflowX: "auto", lineHeight: 1.55, whiteSpace: "pre-wrap" }}>
    {children}
  </pre>
);

const H = ({ children, color = C.white }) => (
  <h3 style={{ color, fontSize: 15, fontWeight: 700, margin: "18px 0 8px 0" }}>{children}</h3>
);

const MathBlock = ({ children }) => (
  <div style={{ background: "#0a0e18", border: `1px solid ${C.accent}30`, borderRadius: 6, padding: "12px 16px", margin: "10px 0", fontFamily: "'JetBrains Mono', monospace", fontSize: 12.5, color: C.cyan, lineHeight: 1.7 }}>
    {children}
  </div>
);

function MathTab() {
  return (
    <div>
      <H>Step 1: What does 20 FPS actually demand?</H>
      <MathBlock>
        YOLOv8n @ 640×640 = <span style={{color:C.yellow}}>8.9 GFLOPs</span> (Ultralytics official)
        {"\n"}1 GFLOP ≈ 0.5 GOPS (1 FLOP = 1 mul + 1 add = 2 ops, but GFLOP counts MAC as 2)
        {"\n"}So: <span style={{color:C.yellow}}>~4.45 billion MAC operations</span> per frame
        {"\n"}
        {"\n"}@ 20 FPS: 4.45G × 20 = <span style={{color:C.red}}>89 GOPS required throughput</span>
        {"\n"}
        {"\n"}@ 320×320: operations scale by (320/640)² = 0.25
        {"\n"}So: 4.45G × 0.25 = 1.11G MACs/frame
        {"\n"}@ 20 FPS: 1.11G × 20 = <span style={{color:C.green}}>22.2 GOPS required</span>
      </MathBlock>

      <H>Step 2: What can ZCU104 deliver?</H>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><Row header cells={["Resource", "Available", "Your Use", "Peak GOPS Contribution"]} /></thead>
        <tbody>
          <Row cells={["DSP48E2 slices", "1,728", "Use for fraction multiply", "1728 × 200M = 345.6 GOPS (INT8 equiv)"]} />
          <Row cells={["LUTs (for Mitchell decode/encode)", "230,400", "Posit decode+encode logic", "Enables DSP feeding"]} />
          <Row cells={["BRAM36", "312", "Weights + feature maps", "~17 GB/s internal BW"]} />
          <Row cells={["URAM", "96", "Large feature map storage", "~3.4 MB on-chip"]} />
          <Row cells={["ARM Cortex-A53 (4 cores)", "4 × 1.2 GHz", "1×1 convs + pre/post", "~4.8 GOPS (NEON INT16)"]} />
          <Row cells={["ARM Cortex-R5 (2 cores)", "2 × 533 MHz", "DMA scheduling", "Control only"]} />
        </tbody>
      </table>

      <Alert type="ok">
        <strong>Key revelation:</strong> You have <strong>1,728 DSP48E2 slices sitting completely unused</strong> in your current design.
        Each DSP48E2 has a 27×18 multiplier + 48-bit accumulator running at 741 MHz max (200+ MHz easily).
        Your Mitchell multiplier avoids DSPs but costs ~300 LUTs each. The trick is: <strong>use DSPs for the fraction×fraction
        correction term AND for the integer accumulation</strong>, keeping Mitchell's log-domain scale computation in LUTs.
      </Alert>

      <H>Step 3: The throughput gap</H>
      <MathBlock>
        Target: 22.2 GOPS (@ 320×320, 20 FPS)
        {"\n"}
        {"\n"}Pure PDPU (32 PEs, Mitchell-only, 200 MHz):
        {"\n"}  32 MACs/cycle × 200M cycles = <span style={{color:C.red}}>6.4 GOPS → only 5.8 FPS</span>
        {"\n"}
        {"\n"}Hybrid approach (DSP-assisted PDPU + ARM co-compute):
        {"\n"}  PL: 128 hybrid PEs × 200M = <span style={{color:C.green}}>25.6 GOPS</span> (using DSPs for fraction mult)
        {"\n"}  PS: ARM 4-core 1×1 conv = <span style={{color:C.green}}>~3-4 GOPS</span>
        {"\n"}  Combined: ~29 GOPS → <span style={{color:C.green}}>26 FPS theoretical @ 320×320</span>
        {"\n"}  With overhead (DMA, im2col): ~60-70% efficiency → <span style={{color:C.yellow}}>~16-18 FPS</span>
        {"\n"}  With pipeline overlap (frame N compute ∥ frame N+1 DMA): <span style={{color:C.green}}>~20-22 FPS</span>
      </MathBlock>

      <Alert type="warn">
        <strong>Resolution trade-off is unavoidable at 20 FPS.</strong> At 640×640, you need 89 GOPS — even with every DSP
        utilized, you can't reach that without multi-hundred PE arrays that won't fit. At 320×320, 20 FPS is
        achievable with the hybrid architecture below. For your paper, run both resolutions and report the FPS curve.
      </Alert>
    </div>
  );
}

function DSPTab() {
  return (
    <div>
      <H>DSP48E2 Anatomy (XCZU7EV)</H>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
        <Box border={C.accent}>
          <div style={{ color: C.accent, fontSize: 12, fontWeight: 700, marginBottom: 6 }}>DSP48E2 Internals</div>
          <div style={{ fontSize: 12, color: C.text, lineHeight: 1.7 }}>
            • 27-bit pre-adder (D ± A){"\n"}
            • <strong style={{color:C.yellow}}>27 × 18 bit multiplier</strong>{"\n"}
            • 48-bit ALU/accumulator{"\n"}
            • Cascade paths (PCOUT→PCIN){"\n"}
            • Runs ≥200 MHz easily on ZCU104{"\n"}
            • <strong>You have 1,728 of these</strong>
          </div>
        </Box>
        <Box border={C.green}>
          <div style={{ color: C.green, fontSize: 12, fontWeight: 700, marginBottom: 6 }}>What Fits in 27×18</div>
          <div style={{ fontSize: 12, color: C.text, lineHeight: 1.7 }}>
            • Your Posit16 fraction: <strong>11 bits</strong>{"\n"}
            • 11 × 11 = 22 bits → <strong>fits in one DSP</strong>{"\n"}
            • Even 12 × 12 fits (27×18){"\n"}
            • The 48-bit acc handles your 32-bit accumulation{"\n"}
            • <strong>1 DSP replaces your entire Mitchell correction LUT + the fraction multiply path</strong>
          </div>
        </Box>
      </div>

      <H>The Hybrid Mitchell-DSP Multiplier</H>
      <p style={{ color: C.text, fontSize: 13, lineHeight: 1.7 }}>
        Your current Mitchell multiplier does everything in LUTs: decode Posit, add log-domain scales,
        approximate fraction product, correction LUT, encode back. The key insight is to <strong>split the work</strong>:
      </p>

      <Box border={C.cyan} mt={8}>
        <div style={{ fontFamily: "monospace", fontSize: 12, color: C.text, lineHeight: 2 }}>
          <div style={{ display: "grid", gridTemplateColumns: "auto 1fr auto", gap: "4px 12px", alignItems: "center" }}>
            <Tag color={C.accent}>LUT</Tag>
            <span>Stage 1: Posit16 decode → extract sign, k, exp, frac (11-bit) for both operands</span>
            <span style={{color:C.dim}}>~150 LUT</span>

            <Tag color={C.accent}>LUT</Tag>
            <span>Stage 2: Scale add: scale_r = (2k_a + e_a) + (2k_b + e_b) — 6-bit integer add</span>
            <span style={{color:C.dim}}>~20 LUT</span>

            <Tag color={C.yellow}>DSP</Tag>
            <span><strong>Stage 3: frac_a[10:0] × frac_b[10:0] → 22-bit product</strong> (replaces Mitchell approx + LUT correction)</span>
            <span style={{color:C.green}}>1 DSP48E2</span>

            <Tag color={C.accent}>LUT</Tag>
            <span>Stage 4: Posit16 encode — assemble sign + regime(k_r) + exp_r + frac_product</span>
            <span style={{color:C.dim}}>~120 LUT</span>

            <Tag color={C.yellow}>DSP</Tag>
            <span><strong>Stage 5: 48-bit accumulate</strong> (use DSP cascade PCOUT→PCIN for PE chaining)</span>
            <span style={{color:C.green}}>0 extra DSP (reuse same)</span>
          </div>
        </div>
      </Box>

      <Alert type="ok">
        <strong>This is the critical architecture change.</strong> By using the DSP48E2 for the 11×11 fraction multiply,
        you get an <strong>exact</strong> fraction product (not Mitchell-approximate) which actually <strong>improves your accuracy</strong>
        while simultaneously <strong>freeing ~300 LUTs per PE</strong> (the Mitchell correction LUT and approximation logic).
        The Posit decode/encode stays in LUTs since it's bit-manipulation, not arithmetic.
      </Alert>

      <H>DSP Budget: How many PEs can you build?</H>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><Row header cells={["Component", "DSPs/PE", "LUTs/PE", "Notes"]} /></thead>
        <tbody>
          <Row cells={["Fraction multiply (11×11)", "1", "0", "Replaces Mitchell frac approx"]} />
          <Row cells={["Accumulate (48-bit)", "0*", "0", "*Uses same DSP's built-in acc"]} />
          <Row cells={["Posit decode (both operands)", "0", "~180", "Regime decode + shift"]} />
          <Row cells={["Scale add + clamp", "0", "~30", "6-bit add + comparators"]} />
          <Row cells={["Posit encode", "0", "~130", "Regime build + body assemble"]} />
          <Row cells={["PE pipeline regs + control", "0", "~60", "Weight reg, act shift, FSM"]} />
          <Row cells={[<strong>Total per PE</strong>, <strong>1 DSP</strong>, <strong>~400 LUT</strong>, ""]} />
        </tbody>
      </table>

      <MathBlock>
        DSP budget: 1,728 DSPs → up to <span style={{color:C.green}}>1,728 PEs possible</span> (DSP-limited)
        {"\n"}LUT budget: 230,400 LUTs, need ~30K for infrastructure (DMA, HDMI, FSM, AXI)
        {"\n"}  Available for PEs: ~200,000 LUTs ÷ 400 LUT/PE = <span style={{color:C.green}}>500 PEs</span> (LUT-limited)
        {"\n"}
        {"\n"}But: routing becomes impossible above ~60-70% LUT utilization.
        {"\n"}Practical limit: <span style={{color:C.yellow}}>~128 PEs</span> (~51K LUT = 22% for PEs, comfortable routing)
        {"\n"}DSP usage: 128 DSPs out of 1,728 = <span style={{color:C.green}}>only 7.4% DSP utilization</span>
        {"\n"}
        {"\n"}128 PEs × 200 MHz = <span style={{color:C.green}}>25.6 GOPS peak</span>
      </MathBlock>

      <H>But wait — can we pack 2 PEs per DSP?</H>
      <Alert type="info">
        The DSP48E2 multiplier is 27×18. Your fractions are 11×11. You can potentially pack two 11-bit multiplies
        into one DSP using the pre-adder packing trick (same as INT8 packing). Place frac_a1 at bits [10:0] and
        frac_a2 at bits [22:12] of the A port, multiply by frac_b in the B port (18-bit), then extract two results
        from the 48-bit output. This gives you <strong>2 fraction multiplies per DSP</strong> → 256 effective PEs from 128 DSPs.
        However, this adds extraction LUT cost (~50 LUT) and you need to carefully handle the carry guard bits.
        I'd recommend starting with 1:1 mapping and optimizing later.
      </Alert>
    </div>
  );
}

function HybridTab() {
  return (
    <div>
      <H>Hybrid PE Architecture: LUT (Posit Logic) + DSP (Multiply-Accumulate)</H>
      <Code>{`// ============================================================
// hybrid_pe.sv — Posit16 PE with DSP48E2 fraction multiply
// ============================================================
// 
// DATAFLOW (per clock, when enabled):
//
//  pe_act_in ──┐                    ┌──► pe_act_out (to next PE)
//              ▼                    │
//         ┌─────────┐         ┌────┘
//         │ Posit16 │         │ act_pipe_r
//         │ DECODE  │◄────────┘
//         │ (LUT)   │  weight_r ◄── pe_weight_in (loaded once)
//         └────┬────┘
//              │ {sign_a, k_a, e_a, frac_a[10:0]}
//              │ {sign_b, k_b, e_b, frac_b[10:0]}
//              ▼
//    ┌─────────────────────┐
//    │ SCALE ADD (LUT)     │  scale_r = (2*k_a + e_a) + (2*k_b + e_b)
//    │ ~30 LUTs            │  sign_r  = sign_a ^ sign_b
//    └─────────┬───────────┘
//              │
//    ┌─────────▼───────────┐
//    │ *** DSP48E2 ***     │  A_port = {16'b0, frac_a[10:0]}  (27-bit)
//    │ 27×18 multiplier    │  B_port = {7'b0, frac_b[10:0]}   (18-bit)
//    │ + 48-bit accumulate │  P_port = frac_a × frac_b        (22-bit used)
//    │ 1 DSP slice         │  Also: P += accumulated (MAC mode)
//    └─────────┬───────────┘
//              │ frac_product[21:0]
//    ┌─────────▼───────────┐
//    │ Posit16 ENCODE      │  Assemble: sign_r, k_r, e_r, frac_product
//    │ (LUT) ~130 LUTs     │  → 16-bit Posit result
//    └─────────┬───────────┘
//              │
//              ▼
//         pe_result (Posit16) → accumulator or output`}
      </Code>

      <H>Why this is better than pure Mitchell</H>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><Row header cells={["Metric", "Your Current (Mitchell LUT)", "Hybrid (DSP Fraction)", "Improvement"]} /></thead>
        <tbody>
          <Row cells={["LUTs per PE", "~700 (decode+Mitchell+LUT+encode)", "~400 (decode+scale+encode)", "43% less LUT"]} />
          <Row cells={["DSPs per PE", "0", "1", "Uses otherwise idle resource"]} />
          <Row cells={["Fraction accuracy", "~1% MRE (Mitchell approx)", "Exact (binary multiply)", "Perfect fraction"]} />
          <Row cells={["Max PEs (practical)", "~32 (LUT-limited)", "~128 (routing-limited)", "4× more PEs"]} />
          <Row cells={["Peak throughput @200MHz", "6.4 GOPS", "25.6 GOPS", "4× throughput"]} />
          <Row cells={["Critical path", "Mitchell LUT + encode", "DSP multiply (fixed 1 cycle)", "Better Fmax"]} />
          <Row cells={["Correction LUT (BRAM)", "1 BRAM36 per PE", "0", "Frees 128 BRAMs"]} />
        </tbody>
      </table>

      <Alert type="warn">
        <strong>Academic framing:</strong> You're not abandoning Mitchell — you're <strong>upgrading</strong> it. The log-domain scale
        computation (regime + exponent addition) is still Mitchell's insight. You're just replacing the approximate
        fraction product with an exact DSP multiply. Your paper can present this as "Mitchell-DSP hybrid: combining
        log-domain Posit scale arithmetic with DSP-accelerated fraction computation." The scale path is the novel
        Posit contribution; the fraction multiply is just arithmetic the DSP was designed for.
      </Alert>

      <H>DSP48E2 Accumulator Cascade</H>
      <p style={{ color: C.text, fontSize: 13, lineHeight: 1.7 }}>
        Instead of your current integer accumulator + separate reduction tree, you can chain DSP48E2s using the
        built-in PCOUT→PCIN cascade. Each DSP computes (frac_a × frac_b) + PCIN in one cycle. For a 16-PE group,
        this means the partial sums ripple through 16 cascaded DSPs in 16 cycles — no separate reduction tree needed.
      </p>
      <Code>{`// DSP cascade for accumulation (conceptual):
// PE[0].DSP: P = frac_a0 * frac_b0                    → PCOUT
// PE[1].DSP: P = frac_a1 * frac_b1 + PE[0].PCOUT      → PCOUT  
// PE[2].DSP: P = frac_a2 * frac_b2 + PE[1].PCOUT      → PCOUT
// ...
// PE[15].DSP: P = frac_a15 * frac_b15 + PE[14].PCOUT   → FINAL SUM
//
// CAVEAT: This cascades FRACTION products, not full Posit values.
// Since each product has a different scale factor, you can't directly
// cascade. Instead, use the DSP accumulator for the FIXED-POINT 
// accumulation AFTER scale-normalizing all products to a common exponent.
//
// Better approach: Use DSP for multiply only, accumulate in a 
// separate 32-bit integer accumulator (your current design works).
// The DSP frees LUTs; the accumulator stays in LUTs or uses
// DSP48E2 in pure-adder mode (OPMODE for C+P).`}
      </Code>
    </div>
  );
}

function ARMTab() {
  return (
    <div>
      <H>ARM Cortex-A53 Co-Compute Strategy</H>
      <p style={{ color: C.text, fontSize: 13, lineHeight: 1.7 }}>
        The ZCU104's PS has 4× ARM Cortex-A53 cores at 1.2 GHz with NEON SIMD. This is a significant compute
        resource that your PRD currently only uses for DMA scheduling and post-processing. For 20 FPS, you
        need to recruit the ARM as an active compute participant.
      </p>

      <H>YOLOv8n Layer Compute Distribution</H>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><Row header cells={["Layer Type", "Count", "% of Total MACs", "Best On", "Rationale"]} /></thead>
        <tbody>
          <Row cells={["Conv 3×3 (backbone)", "~15", "~62%", <Tag color={C.yellow}>PL (PDPU)</Tag>, "Compute-heavy, parallelizable"]} />
          <Row cells={["Conv 1×1 (neck/head)", "~25", "~25%", <Tag color={C.cyan}>PS (ARM NEON)</Tag>, "Memory-bound, small kernels"]} />
          <Row cells={["C2f bottleneck residual adds", "~18", "~3%", <Tag color={C.cyan}>PS (ARM)</Tag>, "Simple element-wise, fast on ARM"]} />
          <Row cells={["SPPF maxpool", "3", "~1%", <Tag color={C.cyan}>PS (ARM)</Tag>, "Comparison only, trivial"]} />
          <Row cells={["Upsample (nearest)", "2", "~0%", <Tag color={C.cyan}>PS (ARM)</Tag>, "Zero arithmetic, memory copy"]} />
          <Row cells={["Concat", "4", "~0%", <Tag color={C.cyan}>PS (ARM)</Tag>, "Pointer manipulation"]} />
          <Row cells={["SiLU activation", "~40", "~8%", <Tag color={C.accent}>Either</Tag>, "LUT on PL or vectorized on PS"]} />
          <Row cells={["Head decode (sigmoid/DFL)", "3", "~1%", <Tag color={C.cyan}>PS (ARM)</Tag>, "Already planned for PS"]} />
        </tbody>
      </table>

      <Alert type="ok">
        <strong>The 1×1 convolutions are the perfect ARM offload target.</strong> They're essentially matrix-vector multiplies
        with no spatial locality benefit — they're memory-bound, not compute-bound. On ARM NEON, a 1×1 conv is
        just a vectorized dot product across channels. With 4 cores, you can process 4 output channels simultaneously.
      </Alert>

      <H>ARM NEON Posit16 Strategy</H>
      <Box border={C.cyan} mt={8}>
        <div style={{ fontSize: 13, color: C.text, lineHeight: 1.7 }}>
          <strong style={{ color: C.cyan }}>Option 1: Native Posit16 on ARM (slower but pure)</strong>
          <br />Use SoftPosit library compiled with -O3 for ARM. Each Posit16 MAC takes ~15-20ns.
          4 cores × 1.2 GHz / 20ns = ~240 MOPS. Too slow for the 25% workload.
        </div>
      </Box>
      <Box border={C.green} mt={8}>
        <div style={{ fontSize: 13, color: C.text, lineHeight: 1.7 }}>
          <strong style={{ color: C.green }}>Option 2: Convert to INT16 at PS-PL boundary (RECOMMENDED)</strong>
          <br />When a feature map exits PL → PS DRAM, convert Posit16 → INT16 fixed-point (in PL, single LUT per element).
          ARM NEON does 8× INT16 MACs per cycle natively. 4 cores × 1.2 GHz × 8 = <strong>38.4 GOPS INT16</strong>.
          Convert back to Posit16 when result returns to PL. The conversion error is bounded and measurable.
          <br /><br />
          <strong>This alone gives you more than enough for all 1×1 convs + activations + residual adds.</strong>
        </div>
      </Box>
      <Box border={C.yellow} mt={8}>
        <div style={{ fontSize: 13, color: C.text, lineHeight: 1.7 }}>
          <strong style={{ color: C.yellow }}>Option 3: FP16 on ARM (pragmatic for demo)</strong>
          <br />ARM Cortex-A53 supports FP16 via NEON. Convert Posit16 → FP16 at boundary (very cheap mapping
          since both are 16-bit with similar range). This gives ~19.2 GOPS FP16 per 4 cores.
          Acceptable accuracy loss for demo. Not recommended for paper accuracy benchmarks.
        </div>
      </Box>

      <H>Compute Split at 320×320</H>
      <MathBlock>
        Total MACs @ 320×320: ~1.11 billion per frame
        {"\n"}
        {"\n"}PL (3×3 convs, 62%): 0.69G MACs → 128 PEs @ 200M = 25.6 GOPS
        {"\n"}  Time: 0.69G / 25.6G = <span style={{color:C.green}}>27 ms</span>
        {"\n"}
        {"\n"}PS (1×1 convs + rest, 38%): 0.42G MACs → NEON INT16 @ 38.4 GOPS
        {"\n"}  Time: 0.42G / 38.4G = <span style={{color:C.green}}>11 ms</span>
        {"\n"}
        {"\n"}If PL and PS run in <span style={{color:C.yellow}}>PARALLEL</span> (PS computes layer N's 1×1
        {"\n"}while PL computes layer N+1's 3×3):
        {"\n"}  Critical path = max(27, 11) = <span style={{color:C.green}}>27 ms → 37 FPS theoretical</span>
        {"\n"}
        {"\n"}With DMA overhead + sync (~40% penalty):
        {"\n"}  <span style={{color:C.green}}>~22 FPS realistic</span>
      </MathBlock>
    </div>
  );
}

function PipelineTab() {
  return (
    <div>
      <H>Triple-Pipeline Overlap Strategy</H>
      <p style={{ color: C.text, fontSize: 13, lineHeight: 1.7 }}>
        The key to hitting 20 FPS is not just raw compute — it's hiding latency through overlap. You need three
        things happening simultaneously:
      </p>

      <Box mt={8}>
        <div style={{ fontFamily: "monospace", fontSize: 11, color: C.text, lineHeight: 1.6, whiteSpace: "pre" }}>
{`TIME ──────────────────────────────────────────────────────────►

Frame N:   [CAPTURE][ PS: resize+convert ][  DMA→PL  ]
Frame N-1:                                [ PL: 3×3 conv ][ PS: 1×1 conv ]
Frame N-2:                                                                [NMS+display]

─────────────────────────────────────────────────────────────────
LAYER-LEVEL PIPELINE (within one frame):

Layer 1:  [DMA wt1][  PL: 3×3 conv1  ]
Layer 2:           [DMA wt2][  PL: 3×3 conv2  ]  ← weight DMA overlaps compute
Layer 3:                    [DMA wt3][  PL: 3×3 conv3  ]
Layer 3': [=== PS: 1×1 conv from layer 2 result ===]  ← PS runs in parallel
Layer 4:                             [DMA wt4][  PL: 3×3 conv4  ]
Layer 4': [========= PS: 1×1 conv from layer 3 =========]

─────────────────────────────────────────────────────────────────
DMA DOUBLE-BUFFER (within one layer):

BRAM Bank A: [COMPUTE layer N] ─────────────────────── [COMPUTE layer N+2]
BRAM Bank B: ────── [DMA LOAD layer N+1 weights] ───── [COMPUTE layer N+1] ──
             ^swap                               ^swap`}
        </div>
      </Box>

      <H>PYNQ + asyncio for Frame-Level Pipeline</H>
      <Code>{`# Python (PS-side) frame pipeline using asyncio
import asyncio
from pynq import Overlay, allocate

overlay = Overlay('posit_yolov8.bit')
dma = overlay.axi_dma_0
accel = overlay.pdpu_accel

async def capture_frame(cam, buf):
    """Capture + resize + posit16 convert"""
    frame = cam.read()
    resized = cv2.resize(frame, (320, 320))
    buf[:] = float_to_posit16(resized)  # Vectorized conversion

async def run_3x3_on_pl(input_buf, weight_buf, output_buf, layer_cfg):
    """DMA input to PL, trigger compute, DMA result back"""
    dma.sendchannel.transfer(input_buf)
    dma.recvchannel.transfer(output_buf)
    accel.write(0x10, layer_cfg)  # Write layer config registers
    accel.write(0x00, 1)          # Start
    await dma.sendchannel.wait_async()
    await dma.recvchannel.wait_async()

async def run_1x1_on_ps(input_arr, weights, output_arr):
    """ARM NEON 1×1 conv (runs as numpy INT16 matmul)"""
    # Convert posit16 buffer to int16 for NEON
    inp_i16 = posit16_to_int16(input_arr)
    wt_i16 = posit16_to_int16(weights)
    out_i16 = np.dot(wt_i16, inp_i16)  # NEON-accelerated
    output_arr[:] = int16_to_posit16(out_i16)

async def inference_pipeline():
    while True:
        # These run concurrently:
        frame_task = asyncio.create_task(capture_frame(cam, buf_in))
        pl_task = asyncio.create_task(run_3x3_on_pl(...))
        ps_task = asyncio.create_task(run_1x1_on_ps(...))
        await asyncio.gather(frame_task, pl_task, ps_task)`}
      </Code>

      <Alert type="info">
        <strong>PYNQ's DMA driver is asyncio-native.</strong> This is specifically documented for the ZCU104.
        You can use <code>wait_async()</code> on DMA transfers to overlap PL compute with PS compute.
        The PYNQ video library also supports async frame read/write for HDMI.
      </Alert>
    </div>
  );
}

function FullTab() {
  return (
    <div>
      <H>Complete 20-FPS Architecture</H>
      <Box>
        <div style={{ fontFamily: "monospace", fontSize: 11, color: C.text, lineHeight: 1.5, whiteSpace: "pre", overflowX: "auto" }}>
{`┌─────────────────────────────────────────────────────────────────────┐
│                         ZCU104 BOARD                                │
│                                                                     │
│  ┌──────────────── PS (ARM Cortex-A53 × 4) ──────────────────────┐ │
│  │                                                                │ │
│  │  Core 0: Frame capture + resize + Posit16↔INT16 convert       │ │
│  │  Core 1-3: 1×1 convolution (NEON INT16 vectorized)            │ │
│  │            + SiLU activation (LUT array in ARM cache)         │ │
│  │            + Residual add + SPPF maxpool + Upsample           │ │
│  │  Core 0: NMS + bbox decode + OpenCV overlay                   │ │
│  │                                                                │ │
│  │  PYNQ overlay driver (asyncio DMA management)                 │ │
│  │                                                                │ │
│  └──────┬────────────────────────┬────────────────────┬──────────┘ │
│         │ AXI4 HP0               │ AXI4 HP1           │ AXI-Lite   │
│         │ (weight DMA)           │ (feature DMA)      │ (control)  │
│  ┌──────▼────────────────────────▼────────────────────▼──────────┐ │
│  │                                                                │ │
│  │                    PL (Programmable Logic)                     │ │
│  │                                                                │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │              LAYER CONTROLLER FSM                        │  │ │
│  │  │  • Sequences 3×3 conv layers only (1×1 offloaded to PS) │  │ │
│  │  │  • Ping-pong BRAM management                            │  │ │
│  │  │  • Weight DMA double-buffer scheduling                  │  │ │
│  │  │  • Im2col configuration per layer                       │  │ │
│  │  │  • PS interrupt on layer completion                     │  │ │
│  │  └─────────────────────┬───────────────────────────────────┘  │ │
│  │                        │                                      │ │
│  │  ┌─────────────────────▼───────────────────────────────────┐  │ │
│  │  │              IM2COL BUFFER                               │  │ │
│  │  │  • Reads from Input Feature Map BRAM                    │  │ │
│  │  │  • Produces flat 3×3×Cin vectors                        │  │ │
│  │  │  • Same-padding with Posit16 zero (0x0000)              │  │ │
│  │  └─────────────────────┬───────────────────────────────────┘  │ │
│  │                        │                                      │ │
│  │  ┌─────────────────────▼───────────────────────────────────┐  │ │
│  │  │         HYBRID PDPU ARRAY  (128 PEs in 8 banks × 16)   │  │ │
│  │  │                                                         │  │ │
│  │  │  Bank 0: [PE0]→[PE1]→...→[PE15] ──► Reduction Tree 0   │  │ │
│  │  │  Bank 1: [PE16]→[PE17]→...→[PE31] ──► Reduction Tree 1 │  │ │
│  │  │  ...                                                    │  │ │
│  │  │  Bank 7: [PE112]→...→[PE127] ──► Reduction Tree 7      │  │ │
│  │  │                                                         │  │ │
│  │  │  Each PE:                                               │  │ │
│  │  │    [Posit16 Decode (LUT)] → [DSP48E2: frac multiply]   │  │ │
│  │  │    → [Scale Add (LUT)] → [Posit16 Encode (LUT)]        │  │ │
│  │  │    → [32-bit Accumulator (LUT)]                         │  │ │
│  │  │                                                         │  │ │
│  │  │  8 banks compute 8 output channels simultaneously      │  │ │
│  │  │  = OUTPUT PARALLELISM (Tm=8)                            │  │ │
│  │  │  16 PEs per bank = INPUT PARALLELISM (Tn=16)            │  │ │
│  │  │                                                         │  │ │
│  │  │  Resources: 128 DSP48E2 (7%) + ~51K LUT (22%)          │  │ │
│  │  └─────────────────────┬───────────────────────────────────┘  │ │
│  │                        │                                      │ │
│  │  ┌─────────────────────▼───────────────────────────────────┐  │ │
│  │  │    OUTPUT WRITER → Output BRAM → DMA → PS DRAM          │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  │                                                                │ │
│  │  ┌─── MEMORY ────────────────────────────────────────────────┐│ │
│  │  │  BRAM: Weight bank A (ping) + Weight bank B (pong)        ││ │
│  │  │  BRAM: Input feature map + Output feature map             ││ │
│  │  │  URAM: Large feature maps (P3 80×80 tiles)                ││ │
│  │  └───────────────────────────────────────────────────────────┘│ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  LPDDR4 (4 GB): All weights (3.2MB) + frame buffers + feature maps │
│                                                                     │
│  [HDMI-In] ──► PS DRAM ──► ... ──► PS DRAM ──► [DisplayPort Out]   │
└─────────────────────────────────────────────────────────────────────┘`}
        </div>
      </Box>

      <H>Resource Estimate Summary</H>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><Row header cells={["Resource", "Used", "Available", "%", "Status"]} /></thead>
        <tbody>
          <Row cells={["LUT", "~92K", "230,400", "40%", <Tag color={C.green}>Comfortable</Tag>]} />
          <Row cells={["DSP48E2", "128", "1,728", "7%", <Tag color={C.green}>Minimal</Tag>]} />
          <Row cells={["BRAM36", "~180", "312", "58%", <Tag color={C.yellow}>Moderate</Tag>]} />
          <Row cells={["URAM", "~48", "96", "50%", <Tag color={C.green}>OK</Tag>]} />
          <Row cells={["FF (est.)", "~65K", "460,800", "14%", <Tag color={C.green}>Fine</Tag>]} />
        </tbody>
      </table>
    </div>
  );
}

function CodeTab() {
  return (
    <div>
      <H>Key RTL Changes from Current PDPU Code</H>

      <Alert type="info">
        <strong>Changes are surgical — not a rewrite.</strong> Your decode/encode logic mostly stays. The Mitchell
        multiplier body gets replaced. The PE wrapper changes slightly. The array needs a generate loop.
      </Alert>

      <H color={C.yellow}>1. Replace pdpu_mitchell_mult.v → hybrid_posit_mult.sv</H>
      <Code>{`module hybrid_posit_mult #(
    parameter POSIT_WIDTH = 16, ES = 1, REGIME_MAX = 3
)(
    input  wire                   clk, rst, en,
    input  wire [POSIT_WIDTH-1:0] mult_a, mult_b,
    output reg  [POSIT_WIDTH-1:0] mult_result,
    output reg                    mult_valid
);

// ── Stage 1: Decode (KEEP your existing decode logic) ──────────
// ... (same as current lines 16-93 of pdpu_mitchell_mult.v)
// Outputs: sign_a, k_a, exp_a, frac_a[10:0]
//          sign_b, k_b, exp_b, frac_b[10:0]

// ── Stage 2: Scale add (KEEP - this IS the Mitchell innovation) ─
wire signed [5:0] scale_a = $signed({k_a, exp_a});
wire signed [5:0] scale_b = $signed({k_b, exp_b});
wire signed [6:0] scale_r_wide = scale_a + scale_b;
// ... (same clamping logic as current)

// ── Stage 3: REPLACE Mitchell fraction approx with DSP48E2 ─────
// OLD: frac_sum = frac_a + frac_b (Mitchell first-order approx)
// OLD: correction LUT for frac_a * frac_b
// NEW: Exact multiply via DSP
wire [21:0] frac_product;  // 11 × 11 = 22 bits

// Vivado will infer DSP48E2 from this:
// (or explicitly instantiate for control)
assign frac_product = frac_a * frac_b;  // → maps to DSP48E2

// Normalize: frac_product is 0.frac_a × 0.frac_b in [0, 1)
// Take top 11 bits as result fraction
wire frac_overflow = frac_product[21];  // if both fracs > 0.5
wire [10:0] frac_r = frac_overflow 
    ? frac_product[20:10]   // shift right by 1, adjust scale
    : frac_product[21:11];  // take MSBs

// Adjust scale if fraction overflowed
wire signed [6:0] scale_adj = frac_overflow 
    ? scale_r_wide + 1 
    : scale_r_wide;

// ── Stage 4: Encode (KEEP your existing encode logic) ───────────
// ... (same case statement building body from k_r, exp_r, frac_r)

endmodule`}</Code>

      <H color={C.yellow}>2. Parameterize pdpu_array.sv for N banks × M PEs</H>
      <Code>{`module pdpu_array_banked #(
    parameter N_BANKS = 8,     // output parallelism (Tm)
    parameter N_PES   = 16,    // input parallelism per bank (Tn)
    parameter POSIT_WIDTH = 16,
    parameter ACC_WIDTH   = 32
)(
    input  wire clk, rst, en,
    input  wire arr_load_weights, arr_acc_clear, arr_dot_done,
    input  wire [N_BANKS*N_PES-1:0][POSIT_WIDTH-1:0] arr_weights,
    input  wire [POSIT_WIDTH-1:0] arr_act_in,  // shared across banks
    output wire [N_BANKS-1:0][POSIT_WIDTH-1:0] arr_results,
    output wire [N_BANKS-1:0] arr_results_valid
);

genvar b, p;
generate
  for (b = 0; b < N_BANKS; b = b + 1) begin : gen_bank
    // Each bank: independent weight set, shared activation stream
    wire [POSIT_WIDTH-1:0] act_chain [0:N_PES];
    assign act_chain[0] = arr_act_in;  // same activation for all banks

    wire [ACC_WIDTH-1:0] acc_out [0:N_PES-1];

    for (p = 0; p < N_PES; p = p + 1) begin : gen_pe
      hybrid_pe #(...) u_pe (
        .clk(clk), .rst(rst), .en(en),
        .pe_weight_in(arr_weights[b*N_PES + p]),
        .pe_act_in(act_chain[p]),
        .pe_act_out(act_chain[p+1]),
        .pe_acc_out(acc_out[p]),
        ...
      );
    end

    // Reduction tree per bank
    reduction_tree #(.N_PES(N_PES), ...) u_tree (
      .tree_acc_in(acc_out),
      .tree_result(arr_results[b]),
      .tree_result_valid(arr_results_valid[b]),
      ...
    );
  end
endgenerate

endmodule`}</Code>

      <H color={C.yellow}>3. Add Posit16 ↔ INT16 converter (for PS boundary)</H>
      <Code>{`// Lightweight Posit16 → INT16 fixed-point converter
// Used at PL→PS boundary so ARM NEON can process 1×1 convs
module posit16_to_int16 (
    input  wire [15:0] posit_in,
    output wire [15:0] int16_out
);
// Decode posit → sign, scale, fraction
// Scale to fixed-point: int16 = sign * (1.fraction) << scale
// Clamp to INT16 range [-32768, 32767]
// This is pure combinational LUT logic, ~100 LUTs
endmodule`}</Code>
    </div>
  );
}

function VerdictTab() {
  return (
    <div>
      <H>Can You Hit 20 FPS? — Honest Assessment</H>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginTop: 12 }}>
        <Box border={C.green}>
          <div style={{ color: C.green, fontWeight: 700, fontSize: 14, marginBottom: 8 }}>At 320×320: YES ✓</div>
          <div style={{ fontSize: 12, color: C.text, lineHeight: 1.7 }}>
            128 hybrid PEs (DSP-assisted) + ARM NEON co-compute + triple pipeline overlap = <strong>~20-22 FPS</strong>.
            Resource utilization stays under 50% for everything. Timing at 200 MHz is achievable.
            This is your realistic demo target.
          </div>
        </Box>
        <Box border={C.red}>
          <div style={{ color: C.red, fontWeight: 700, fontSize: 14, marginBottom: 8 }}>At 640×640: NO ✗</div>
          <div style={{ fontSize: 12, color: C.text, lineHeight: 1.7 }}>
            4× the compute (89 GOPS needed). Even with every optimization, max practical throughput
            on ZCU104 is ~30-35 GOPS. You'd get ~5-7 FPS. Acceptable for benchmarking, not for 20 FPS claim.
            Report both in your paper.
          </div>
        </Box>
      </div>

      <H>The 5 Things That Get You to 20 FPS</H>
      {[
        {
          n: "1", title: "DSP48E2 for fraction multiply",
          desc: "Replace Mitchell LUT approximation with exact 11×11 DSP multiply. Frees ~300 LUT/PE, enables 128+ PEs. Your Mitchell log-domain scale computation stays — this is an upgrade, not a removal.",
          gain: "4× more PEs (32 → 128)", resource: "128 DSPs (7%)",
        },
        {
          n: "2", title: "8-bank output parallelism (Tm=8)",
          desc: "Instead of 1 array computing 1 output channel at a time, instantiate 8 independent arrays of 16 PEs each, all sharing the same activation stream but with different weights. 8 output channels computed simultaneously.",
          gain: "8× throughput per cycle", resource: "Same 128 PEs, reorganized",
        },
        {
          n: "3", title: "ARM NEON co-compute for 1×1 convolutions",
          desc: "Offload all 1×1 convs (25% of MACs) + SiLU + residual adds to PS. Convert Posit16→INT16 at boundary. 4 ARM cores at 1.2 GHz with NEON = ~38 GOPS INT16. Runs in PARALLEL with PL 3×3 convs.",
          gain: "25% workload off PL, runs concurrently", resource: "4 ARM cores (already there)",
        },
        {
          n: "4", title: "Weight DMA double-buffering",
          desc: "Two weight BRAM banks. While PL computes with bank A, DMA pre-loads bank B for next layer. Eliminates weight loading stall between layers.",
          gain: "~30% latency reduction", resource: "2× weight BRAM (still fits)",
        },
        {
          n: "5", title: "Frame-level pipeline with PYNQ asyncio",
          desc: "Capture frame N while inferring frame N-1 while displaying frame N-2. PYNQ's DMA driver supports asyncio natively. PS does preprocessing/postprocessing concurrently with PL compute.",
          gain: "Near-100% utilization", resource: "Software only",
        },
      ].map((item, i) => (
        <Box key={i} mt={10} border={C.accent + "40"}>
          <div style={{ display: "flex", gap: 12, alignItems: "flex-start" }}>
            <div style={{ minWidth: 36, height: 36, background: C.accent + "20", borderRadius: 8, display: "flex", alignItems: "center", justifyContent: "center", color: C.accent, fontWeight: 800, fontSize: 16 }}>
              {item.n}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ color: C.white, fontSize: 14, fontWeight: 700 }}>{item.title}</div>
              <div style={{ color: C.text, fontSize: 12.5, lineHeight: 1.65, marginTop: 4 }}>{item.desc}</div>
              <div style={{ display: "flex", gap: 12, marginTop: 6 }}>
                <Tag color={C.green}>Gain: {item.gain}</Tag>
                <Tag color={C.yellow}>Cost: {item.resource}</Tag>
              </div>
            </div>
          </div>
        </Box>
      ))}

      <H>Modified Timeline Impact</H>
      <Alert type="warn">
        <strong>Honest timeline addition: +3-5 days</strong> over your original PRD. The DSP integration (change 1) adds ~2 days to
        Tier 1. The banked array (change 2) adds ~1 day to Tier 2. The ARM co-compute (change 3) adds ~2 days to Tier 3
        but can parallelize with PL integration. DMA double-buffer and PYNQ pipeline are Days 18-21 work.
        <strong> If your timeline is rigid at 25 days, drop the bank count to 4 (Tm=4) and target 12-15 FPS instead.</strong>
      </Alert>

      <H>Paper Contribution Framing</H>
      <Box border={C.cyan} mt={8}>
        <div style={{ fontSize: 13, color: C.text, lineHeight: 1.7 }}>
          <strong style={{ color: C.cyan }}>"Hybrid Mitchell-DSP Posit Arithmetic for Real-Time Object Detection"</strong>
          <br /><br />
          • <strong>Novel:</strong> First Posit16 YOLOv8 accelerator with DSP-assisted log-domain arithmetic{"\n"}
          • <strong>Insight:</strong> Mitchell's log-domain scale computation in LUTs + exact DSP fraction multiply = best of both worlds{"\n"}
          • <strong>Practical:</strong> 20+ FPS live detection on ZCU104 using PS-PL co-compute{"\n"}
          • <strong>Comparison:</strong> 5-way table — FP32 / Exact Posit16 / Mitchell-only Posit16 / Mitchell-DSP Hybrid / INT8{"\n"}
          • <strong>Result:</strong> Better accuracy than INT8 (Posit16 dynamic range) with competitive throughput
        </div>
      </Box>
    </div>
  );
}

export default function App() {
  const [active, setActive] = useState("math");

  const Content = {
    math: MathTab, dsp: DSPTab, hybrid: HybridTab, arm: ARMTab,
    pipeline: PipelineTab, full: FullTab, code: CodeTab, verdict: VerdictTab,
  };
  const ActiveComponent = Content[active];

  return (
    <div style={{ minHeight: "100vh", background: C.bg, color: C.white, fontFamily: "-apple-system, 'Segoe UI', system-ui, sans-serif" }}>
      <div style={{ maxWidth: 980, margin: "0 auto", padding: "20px 16px" }}>
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 11, color: C.accent, letterSpacing: 2.5, textTransform: "uppercase", fontWeight: 600 }}>
            20 FPS Architecture Plan
          </div>
          <h1 style={{ fontSize: 22, fontWeight: 800, margin: "4px 0 0 0", lineHeight: 1.2 }}>
            YOLOv8n Posit16 — DSP Offload + ARM Co-Compute
          </h1>
          <div style={{ color: C.dim, fontSize: 13, marginTop: 4 }}>
            ZCU104 · 128 Hybrid PEs · 8-Bank Output Parallel · PYNQ Async Pipeline · 320×320 @ 20+ FPS
          </div>
        </div>

        <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginBottom: 20 }}>
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setActive(t.id)}
              style={{
                background: active === t.id ? C.accent : C.card,
                color: active === t.id ? "#fff" : C.dim,
                border: `1px solid ${active === t.id ? C.accent : C.border}`,
                borderRadius: 6, padding: "5px 11px", fontSize: 12, cursor: "pointer",
                fontWeight: active === t.id ? 700 : 400, transition: "all 0.12s",
              }}
            >
              <span style={{ marginRight: 3 }}>{t.icon}</span> {t.label}
            </button>
          ))}
        </div>

        <div style={{ background: C.card, border: `1px solid ${C.border}`, borderRadius: 10, padding: 20 }}>
          <ActiveComponent />
        </div>

        <div style={{ color: C.dim, fontSize: 10, textAlign: "center", marginTop: 14 }}>
          Analysis based on: PDPU RTL (pdpu_pe.sv, pdpu_mitchell_mult.v, pdpu_array.sv) · PRD v3 ·
          DSP48E2 UG579 · PYNQ ZCU104 docs · YOLOv8n 8.9 GFLOPS @ 640²
        </div>
      </div>
    </div>
  );
}

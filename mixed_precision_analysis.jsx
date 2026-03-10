import { useState } from "react";

const C = {
  bg: "#07090e", card: "#0c1018", border: "#1a2030",
  blue: "#3b82f6", green: "#22c55e", red: "#ef4444",
  yellow: "#eab308", cyan: "#06b6d4", text: "#c0c8d8",
  dim: "#4a5568", white: "#f0f4fa", purple: "#a855f7",
};

const Box = ({ children, border = C.border, mt = 0 }) => (
  <div style={{ background: C.card, border: `1px solid ${border}`, borderRadius: 8, padding: 16, marginTop: mt }}>{children}</div>
);
const Tag = ({ color, children }) => (
  <span style={{ background: color + "18", color, padding: "2px 8px", borderRadius: 4, fontSize: 11, fontWeight: 600 }}>{children}</span>
);
const H = ({ children, color = C.white }) => (
  <h3 style={{ color, fontSize: 15, fontWeight: 700, margin: "20px 0 8px 0" }}>{children}</h3>
);
const P = ({ children }) => (
  <p style={{ color: C.text, fontSize: 13.5, lineHeight: 1.72, margin: "6px 0" }}>{children}</p>
);
const Alert = ({ type = "info", children }) => {
  const m = { info: C.blue, warn: C.yellow, crit: C.red, ok: C.green };
  return (
    <div style={{ borderLeft: `3px solid ${m[type]}`, background: m[type] + "08", padding: "10px 14px", margin: "12px 0", borderRadius: "0 6px 6px 0", fontSize: 13, color: C.text, lineHeight: 1.65 }}>{children}</div>
  );
};
const Code = ({ children }) => (
  <pre style={{ background: "#080c14", border: `1px solid ${C.border}`, borderRadius: 6, padding: 14, fontSize: 11.5, color: "#8ba4c4", fontFamily: "'JetBrains Mono', monospace", margin: "10px 0", overflowX: "auto", lineHeight: 1.5, whiteSpace: "pre-wrap" }}>{children}</pre>
);
const Row = ({ cells, header }) => (
  <tr>
    {cells.map((c, i) => {
      const T = header ? "th" : "td";
      return <T key={i} style={{ padding: "7px 10px", borderBottom: `1px solid ${C.border}`, textAlign: i === 0 ? "left" : "center", fontWeight: header ? 700 : 400, color: header ? C.cyan : C.text, fontSize: 12.5, background: header ? C.bg : "transparent" }}>{c}</T>;
    })}
  </tr>
);

const tabs = [
  { id: "where", label: "Where Are the 0s and 1s?", icon: "?" },
  { id: "mixed", label: "Smart Mixed Precision", icon: "⊕" },
  { id: "speedup", label: "Does It Actually Help?", icon: "⚡" },
  { id: "plan", label: "25-Day Practical Plan", icon: "✓" },
];

function WhereTab() {
  return (<div>
    <H>Tracing the data through YOLOv8n — where do values become 0 or 1?</H>
    <P>Short answer: they never do, inside the network. Every intermediate value is a continuous real number. Here's what each stage actually outputs:</P>

    <div style={{ display: "flex", flexDirection: "column", gap: 8, margin: "16px 0" }}>
      {[
        { stage: "Input image", values: "0–255 per pixel → normalized to 0.0–1.0", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "Conv2d 3×3 outputs", values: "Typically range [-2.0, +4.0] after BN-fold", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "SiLU activation", values: "SiLU(x) = x·σ(x), smooth curve, range (-0.28, +∞)", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "C2f bottleneck residual", values: "Sum of two feature maps, continuous", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "SPPF maxpool", values: "Max of nearby values, continuous", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "Neck (FPN+PAN) concat", values: "Channel concatenation, no arithmetic change", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "Head conv outputs (raw logits)", values: "Unbounded real numbers (e.g., -3.2, +5.7)", precision: "Continuous", format: "Posit16", binary: false },
        { stage: "Sigmoid on class scores", values: "0.0 to 1.0 (probabilities like 0.87, 0.03)", precision: "Continuous [0,1]", format: "Float32 (PS)", binary: false },
        { stage: "NMS confidence threshold", values: "keep if score > 0.25 → TRUE/FALSE", precision: "BINARY ✓", format: "Bool (PS)", binary: true },
        { stage: "NMS IoU suppression", values: "suppress if overlap > 0.45 → TRUE/FALSE", precision: "BINARY ✓", format: "Bool (PS)", binary: true },
        { stage: "Final bounding boxes", values: "[x, y, w, h, class_id, confidence]", precision: "Continuous + int", format: "Float32 (PS)", binary: false },
      ].map((r, i) => (
        <div key={i} style={{
          display: "flex", gap: 12, padding: "8px 12px", borderRadius: 6,
          background: r.binary ? C.green + "10" : C.card,
          border: `1px solid ${r.binary ? C.green + "40" : C.border}`,
          alignItems: "center",
        }}>
          <div style={{ minWidth: 28, height: 28, borderRadius: 6, background: r.binary ? C.green + "20" : C.blue + "15", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 12, color: r.binary ? C.green : C.blue, fontWeight: 700 }}>
            {i + 1}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ color: C.white, fontSize: 13, fontWeight: 600 }}>{r.stage}</div>
            <div style={{ color: C.dim, fontSize: 11.5, marginTop: 1 }}>{r.values}</div>
          </div>
          <div style={{ display: "flex", gap: 6, flexShrink: 0 }}>
            <Tag color={r.binary ? C.green : C.purple}>{r.precision}</Tag>
            <Tag color={C.cyan}>{r.format}</Tag>
          </div>
        </div>
      ))}
    </div>

    <Alert type="ok">
      <strong>The only true binary decisions (steps 9-10) happen in NMS on the PS ARM cores in float32.</strong> They take ~2-3 ms total and are already outside your PDPU compute path. There's nothing to optimize there — it's already fast.
    </Alert>

    <H>But wait — what about ReLU-like sparsity?</H>
    <P>
      You might be thinking of <strong>activation sparsity</strong> — the fact that ReLU(x) = 0 for all x &lt; 0, producing lots of exact zeros. This is a real phenomenon that some accelerators exploit (skipping zero-valued multiplications). However, YOLOv8 uses <strong>SiLU, not ReLU</strong>. SiLU(x) for negative x is small but never exactly zero (SiLU(-3) ≈ -0.14, SiLU(-5) ≈ -0.03). So you don't get the clean sparsity that ReLU-based networks have. There's no shortcut here.
    </P>

    <Alert type="warn">
      <strong>If you wanted to exploit sparsity</strong>, you'd need to retrain YOLOv8n with ReLU instead of SiLU, then add zero-skipping logic to your PEs (check if activation == 0x0000, skip the multiply-accumulate). This could give 30-50% speedup on backbone layers but costs you some mAP and adds ~2 days of retraining. Not recommended for your 25-day window.
    </Alert>
  </div>);
}

function MixedTab() {
  return (<div>
    <H>Your instinct is right — just aimed at the wrong boundary</H>
    <P>
      Instead of "binary vs Posit16," the real mixed-precision opportunity is <strong>"which layers need Posit16's dynamic range, and which can run on cheaper INT8?"</strong> This is exactly what NVIDIA does with TensorRT's mixed-precision — except you're choosing between Posit16 and INT8 instead of FP16 and INT8.
    </P>

    <H color={C.yellow}>Layer-by-Layer Precision Sensitivity in YOLOv8n</H>
    <table style={{ width: "100%", borderCollapse: "collapse", margin: "12px 0" }}>
      <thead><Row header cells={["Layer Group", "Layers", "Precision Sensitivity", "Recommended", "Why"]} /></thead>
      <tbody>
        <Row cells={[
          "Early backbone (P1-P2)",
          "Conv 3×3, stride 2",
          <Tag color={C.green}>LOW</Tag>,
          <Tag color={C.yellow}>INT8 on DSP</Tag>,
          "Simple edge/texture features; high spatial redundancy"
        ]} />
        <Row cells={[
          "Mid backbone (P3-P4)",
          "C2f blocks, Conv 3×3",
          <Tag color={C.yellow}>MEDIUM</Tag>,
          <Tag color={C.blue}>Posit16</Tag>,
          "Semantic features forming; precision helps"
        ]} />
        <Row cells={[
          "Deep backbone (P5) + SPPF",
          "C2f, Conv 3×3, MaxPool",
          <Tag color={C.red}>HIGH</Tag>,
          <Tag color={C.blue}>Posit16</Tag>,
          "Small feature maps; each value matters for detection"
        ]} />
        <Row cells={[
          "Neck 1×1 convs",
          "Pointwise channel mixing",
          <Tag color={C.green}>LOW</Tag>,
          <Tag color={C.yellow}>INT8/INT16 on ARM</Tag>,
          "Channel reweighting; very tolerant of quantization"
        ]} />
        <Row cells={[
          "Neck 3×3 convs",
          "Spatial processing in FPN/PAN",
          <Tag color={C.yellow}>MEDIUM</Tag>,
          <Tag color={C.blue}>Posit16</Tag>,
          "Multi-scale fusion; moderate sensitivity"
        ]} />
        <Row cells={[
          "Head convs",
          "Final 1×1 to box/class outputs",
          <Tag color={C.red}>HIGH</Tag>,
          <Tag color={C.blue}>Posit16</Tag>,
          "Direct impact on bbox coordinates and class scores"
        ]} />
        <Row cells={[
          "Sigmoid + NMS",
          "Post-processing",
          "N/A",
          <Tag color={C.cyan}>FP32 on PS</Tag>,
          "Already on ARM; trivial compute"
        ]} />
      </tbody>
    </table>

    <H>The practical mixed-precision architecture</H>
    <Box border={C.yellow} mt={8}>
      <div style={{ fontFamily: "monospace", fontSize: 12, color: C.text, lineHeight: 1.8 }}>
        <div style={{ color: C.yellow, fontWeight: 700, marginBottom: 8 }}>Option: Dual-mode PE with INT8 fast-path</div>
        {`Each PE has TWO datapaths sharing the same DSP48E2:

Mode A — Posit16 (for sensitive layers):
  [Posit16 decode (LUT)] → [DSP: 11×11 frac mult] → [Posit16 encode (LUT)]
  1 MAC per cycle per PE

Mode B — INT8 packed (for tolerant layers):
  [DSP: two packed INT8 MACs] → [INT32 accumulate]
  2 MACs per cycle per PE  ← 2× THROUGHPUT

The DSP48E2 27×18 multiplier can pack two 8×8 multiplies using
Xilinx's pre-adder packing trick (documented in WP487).

A 1-bit mode select signal per layer chooses the datapath.
Weight BRAM stores Posit16 OR INT8 depending on layer mode.`}
      </div>
    </Box>

    <Alert type="info">
      <strong>The speed gain from dual-mode PEs:</strong> About 30-40% of YOLOv8n's MACs are in early backbone layers that can tolerate INT8. In those layers, each PE does 2 MACs/cycle instead of 1. So your effective throughput is: 0.6 × 25.6 GOPS (Posit16 layers) + 0.4 × 51.2 GOPS (INT8 layers) ≈ <strong>36 GOPS blended</strong> — a 40% improvement over pure Posit16.
    </Alert>

    <H color={C.red}>But here's the honest problem with this for your timeline</H>
    <P>
      A dual-mode PE requires: (1) INT8 weight conversion pipeline (offline, ~1 day), (2) INT8 data path in the PE with mux (~100 extra LUTs per PE, 1 day RTL), (3) layer-level mode configuration in the FSM (~0.5 day), (4) INT8→Posit16 conversion at the boundary between INT8 and Posit16 layers (~0.5 day), (5) accuracy validation that INT8 early layers don't hurt mAP (~1-2 days of experimentation). That's 4-5 days of additional work on top of an already tight 25-day schedule. The 40% throughput gain is real but the time cost is steep.
    </P>

    <Box border={C.green} mt={12}>
      <div style={{ color: C.green, fontSize: 14, fontWeight: 700, marginBottom: 8 }}>Recommendation: Defer dual-mode for the paper, but mention it as future work</div>
      <div style={{ color: C.text, fontSize: 13, lineHeight: 1.7 }}>
        For 25 days, keep the PL path as <strong>pure Posit16 with DSP-assisted fraction multiply</strong>. Offload INT8/INT16 work to the ARM cores (1×1 convs via NEON). This gives you a clean academic contribution ("full Posit16 pipeline") without the complexity of dual-mode PEs. In your paper's future work section, describe the dual-mode architecture and project the 40% throughput gain with a resource estimate. A reviewer will see that as a strong next step.
      </div>
    </Box>
  </div>);
}

function SpeedupTab() {
  return (<div>
    <H>Does mixed precision actually help speed? — Quantified</H>

    <table style={{ width: "100%", borderCollapse: "collapse", margin: "12px 0" }}>
      <thead><Row header cells={["Architecture", "PL PEs", "PL GOPS", "PS GOPS", "Total", "FPS @320²", "Complexity"]} /></thead>
      <tbody>
        <Row cells={[
          "A: Pure Mitchell (your current)",
          "32", "6.4", "0", "6.4",
          <Tag color={C.red}>~3</Tag>,
          <Tag color={C.green}>Low</Tag>
        ]} />
        <Row cells={[
          "B: DSP-hybrid Posit16 only",
          "128", "25.6", "~4 (NEON P16)", "~29",
          <Tag color={C.yellow}>~18</Tag>,
          <Tag color={C.yellow}>Medium</Tag>
        ]} />
        <Row cells={[
          "C: DSP-hybrid + ARM INT16 co-compute",
          "128", "25.6", "~15 (NEON I16)", "~40",
          <Tag color={C.green}>~22</Tag>,
          <Tag color={C.yellow}>Medium</Tag>
        ]} />
        <Row cells={[
          "D: Dual-mode PE (P16+INT8) + ARM",
          "128", "~36", "~15 (NEON I16)", "~51",
          <Tag color={C.green}>~28</Tag>,
          <Tag color={C.red}>High</Tag>
        ]} />
        <Row cells={[
          "E: All-INT8 (abandon Posit, ref only)",
          "128 (2×packed)", "51.2", "~38 (NEON I8)", "~89",
          <Tag color={C.green}>~48</Tag>,
          <Tag color={C.green}>Low (but no paper)</Tag>
        ]} />
      </tbody>
    </table>

    <Alert type="warn">
      <strong>The jump from B→C is the sweet spot.</strong> Going from "DSP-hybrid Posit16 only" to "DSP-hybrid + ARM INT16 co-compute" is mostly a software change (NEON code on PS) with a small Posit16↔INT16 converter in PL. It gets you from ~18 to ~22 FPS with minimal RTL complexity added. The jump from C→D (dual-mode PEs) adds only ~6 FPS but costs 4-5 days and significant RTL complexity. Not worth it in 25 days.
    </Alert>

    <H>What about the accuracy side?</H>
    <P>
      The mixed-precision question matters more for accuracy than speed in your case. Here's why: Posit16 has better precision near 1.0 than INT8, but INT8 has been extensively studied and calibrated for YOLO models. The mAP comparison is the real contribution:
    </P>

    <table style={{ width: "100%", borderCollapse: "collapse", margin: "12px 0" }}>
      <thead><Row header cells={["Format", "Typical mAP@0.5 (YOLOv8n)", "Dynamic Range", "Precision Near 1.0"]} /></thead>
      <tbody>
        <Row cells={["FP32 (baseline)", "37.3%", "±3.4×10³⁸", "23-bit mantissa"]} />
        <Row cells={["FP16", "37.2% (−0.1%)", "±65,504", "10-bit mantissa"]} />
        <Row cells={["INT8 (calibrated)", "36.0-36.8% (−0.5 to −1.3%)", "[-128, 127]", "Uniform 8-bit"]} />
        <Row cells={[<strong style={{color:C.cyan}}>Posit16 (your design)</strong>, <strong>~36.5-37.0%? (TBD)</strong>, "[1/64, 64] (3-bit cap)", "~11-bit frac near 1.0"]} />
        <Row cells={["Mixed P16+INT8", "~36.5%?", "Both", "Best of both"]} />
      </tbody>
    </table>

    <Alert type="ok">
      <strong>Your paper's key result:</strong> If Posit16 achieves mAP within 0.5% of FP32 while INT8 drops 1-1.3%, that's a genuine contribution — better accuracy per bit than INT8 with competitive throughput. The 5-way comparison table (FP32 / FP16 / INT8 / Posit16-Mitchell / Posit16-DSP-hybrid) is publishable regardless of FPS.
    </Alert>

    <H>Where "binary-like" optimization DOES help: zero-skipping</H>
    <P>
      While YOLOv8n doesn't produce binary outputs, there's a related optimization you can add cheaply: <strong>zero-value skipping</strong>. After SiLU, roughly 5-15% of activations are very close to zero (within Posit16's minpos). You already detect zero inputs in your Mitchell multiplier (the <code>is_zero_a | is_zero_b</code> check). Extend this to skip the full MAC when the activation is below a small threshold. Cost: ~10 LUTs per PE for the comparator. Gain: 5-15% fewer MAC cycles.
    </P>
    <Code>{`// In hybrid_pe.sv — add near-zero skip
wire act_is_negligible = (act_pipe_r[14:0] < 15'h0040);  // |x| < minpos threshold
wire skip_mac = is_zero_a | is_zero_b | act_is_negligible;

// If skip_mac: don't accumulate, save 1 cycle of DSP power
// The accumulator stays unchanged (adding 0 is a no-op anyway,
// but skipping avoids toggling the DSP, saving dynamic power)`}</Code>
  </div>);
}

function PlanTab() {
  return (<div>
    <H>Final Practical Plan for 25 Days — What to Actually Build</H>

    <Alert type="ok">
      <strong>The architecture you should implement:</strong> Architecture C from the comparison table. DSP-hybrid Posit16 on PL (128 PEs) + ARM NEON INT16 co-compute on PS. This gives ~20-22 FPS at 320×320 with a clean academic story.
    </Alert>

    <H color={C.cyan}>Priority stack — what to do and in what order</H>
    {[
      {
        pri: "P0", title: "Hybrid PE: DSP fraction multiply",
        days: "Days 1-4",
        desc: "Replace Mitchell fraction approximation with DSP48E2 11×11 multiply. Keep log-domain scale add in LUTs. Validate against SoftPosit reference. This is your most critical RTL change.",
        status: "MUST DO",
        color: C.red,
      },
      {
        pri: "P0", title: "Parameterized array with generate loop",
        days: "Days 4-6",
        desc: "Convert hand-instantiated 4 PEs to generate loop. Start with N_PES=16 for Tier 2 validation, then scale to 128 (8 banks × 16 PEs) for Tier 3.",
        status: "MUST DO",
        color: C.red,
      },
      {
        pri: "P0", title: "Layer controller FSM for 3×3 convolutions",
        days: "Days 6-12",
        desc: "FSM that sequences weight loading, im2col extraction, PDPU compute, and output write for all 3×3 conv layers. The backbone 3×3 convs are your PL workload.",
        status: "MUST DO",
        color: C.red,
      },
      {
        pri: "P1", title: "PYNQ overlay + DMA double-buffer",
        days: "Days 10-14",
        desc: "Flash PYNQ on ZCU104. Build Vivado block design with your PDPU IP + AXI DMA + AXI-Lite control. Test DMA transfers. Implement weight double-buffering.",
        status: "MUST DO",
        color: C.yellow,
      },
      {
        pri: "P1", title: "ARM NEON 1×1 conv + Posit16↔INT16 converter",
        days: "Days 12-16",
        desc: "Build lightweight Posit16→INT16 converter (PL LUT module). Write NEON-optimized 1×1 conv kernel in C for ARM. Run 1×1 convs, SiLU, residual adds on PS. Test accuracy of the conversion.",
        status: "MUST DO",
        color: C.yellow,
      },
      {
        pri: "P1", title: "Live frame loop (capture → infer → display)",
        days: "Days 16-19",
        desc: "HDMI-In or USB camera on PS. Frame resize to 320×320. Asyncio pipeline: capture frame N, infer frame N-1, display frame N-2. Measure actual FPS.",
        status: "MUST DO",
        color: C.yellow,
      },
      {
        pri: "P2", title: "Timing closure + optimization",
        days: "Days 19-21",
        desc: "Target ≥200 MHz. Apply 2-hop pipelining if needed. Optimize DMA burst lengths. Tune asyncio scheduling.",
        status: "IMPORTANT",
        color: C.blue,
      },
      {
        pri: "P2", title: "mAP benchmarking + 5-way comparison",
        days: "Days 21-24",
        desc: "COCO val2017 (500+ images). Generate the comparison table: FP32 / FP16 / INT8 / Posit16 / Posit16-DSP-hybrid. Record FPS, power, resource utilization.",
        status: "IMPORTANT",
        color: C.blue,
      },
      {
        pri: "P3", title: "Paper write-up + demo video",
        days: "Days 24-25",
        desc: "Architecture diagrams, results tables, live detection demo recording. Mention dual-mode INT8+Posit16 PE as future work.",
        status: "FINISH",
        color: C.green,
      },
    ].map((item, i) => (
      <Box key={i} mt={8} border={item.color + "40"}>
        <div style={{ display: "flex", gap: 12, alignItems: "flex-start" }}>
          <div style={{ minWidth: 36, textAlign: "center" }}>
            <div style={{ background: item.color + "20", color: item.color, padding: "2px 8px", borderRadius: 4, fontSize: 11, fontWeight: 700 }}>{item.pri}</div>
            <div style={{ color: C.dim, fontSize: 10, marginTop: 4 }}>{item.days}</div>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div style={{ color: C.white, fontSize: 13.5, fontWeight: 700 }}>{item.title}</div>
              <Tag color={item.color}>{item.status}</Tag>
            </div>
            <div style={{ color: C.text, fontSize: 12.5, lineHeight: 1.6, marginTop: 4 }}>{item.desc}</div>
          </div>
        </div>
      </Box>
    ))}

    <H color={C.yellow}>Things to NOT spend time on (save for future work)</H>
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginTop: 8 }}>
      {[
        ["Dual-mode INT8+Posit16 PE", "4-5 days, only 40% gain"],
        ["ReLU replacement for sparsity", "Needs retraining"],
        ["2D systolic array", "Your PRD already scoped this out"],
        ["640×640 optimization", "Physics says no at 20 FPS"],
        ["Custom NMS accelerator", "NMS is 2ms on ARM, irrelevant"],
        ["Quire accumulator", "PRD already traded this off"],
      ].map(([what, why], i) => (
        <div key={i} style={{ background: C.red + "08", border: `1px solid ${C.red}20`, borderRadius: 6, padding: "8px 12px" }}>
          <div style={{ color: C.red, fontSize: 12, fontWeight: 600 }}>{what}</div>
          <div style={{ color: C.dim, fontSize: 11, marginTop: 2 }}>{why}</div>
        </div>
      ))}
    </div>

    <H>Your paper title suggestion</H>
    <Box border={C.cyan} mt={8}>
      <div style={{ color: C.cyan, fontSize: 15, fontWeight: 700, fontStyle: "italic", lineHeight: 1.5 }}>
        "Real-Time YOLOv8n Object Detection Using Hybrid Mitchell-DSP Posit⟨16,1⟩ Arithmetic on Zynq UltraScale+ FPGA with PS-PL Co-Computation"
      </div>
      <div style={{ color: C.text, fontSize: 12.5, marginTop: 10, lineHeight: 1.65 }}>
        <strong>Contributions claimed:</strong>{"\n"}
        (1) First Posit16 YOLOv8 inference on FPGA (novelty){"\n"}
        (2) Hybrid PE combining Mitchell log-domain scale arithmetic with exact DSP fraction multiply (architecture){"\n"}
        (3) PS-PL co-computation with Posit16↔INT16 boundary conversion for 20+ FPS live detection (systems){"\n"}
        (4) 5-way accuracy comparison showing Posit16 advantages over INT8 for object detection (empirical result)
      </div>
    </Box>
  </div>);
}

export default function App() {
  const [active, setActive] = useState("where");
  const Content = { where: WhereTab, mixed: MixedTab, speedup: SpeedupTab, plan: PlanTab };
  const Comp = Content[active];

  return (
    <div style={{ minHeight: "100vh", background: C.bg, color: C.white, fontFamily: "-apple-system, 'Segoe UI', system-ui, sans-serif" }}>
      <div style={{ maxWidth: 960, margin: "0 auto", padding: "20px 16px" }}>
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 11, color: C.purple, letterSpacing: 2.5, textTransform: "uppercase", fontWeight: 600 }}>
            Mixed Precision Analysis
          </div>
          <h1 style={{ fontSize: 21, fontWeight: 800, margin: "4px 0 0 0" }}>
            Where Are the 0s and 1s? — And What Actually Helps Speed
          </h1>
          <div style={{ color: C.dim, fontSize: 13, marginTop: 4 }}>
            Binary decisions in YOLOv8n · Layer precision sensitivity · Practical 25-day architecture choices
          </div>
        </div>

        <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginBottom: 20 }}>
          {tabs.map((t) => (
            <button key={t.id} onClick={() => setActive(t.id)} style={{
              background: active === t.id ? C.purple : C.card,
              color: active === t.id ? "#fff" : C.dim,
              border: `1px solid ${active === t.id ? C.purple : C.border}`,
              borderRadius: 6, padding: "5px 12px", fontSize: 12, cursor: "pointer",
              fontWeight: active === t.id ? 700 : 400,
            }}>
              <span style={{ marginRight: 3 }}>{t.icon}</span> {t.label}
            </button>
          ))}
        </div>

        <div style={{ background: C.card, border: `1px solid ${C.border}`, borderRadius: 10, padding: 20 }}>
          <Comp />
        </div>
      </div>
    </div>
  );
}

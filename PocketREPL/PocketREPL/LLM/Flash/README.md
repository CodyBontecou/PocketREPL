# LLM in a Flash — Implementation

Implements Apple's ["LLM in a Flash"](https://arxiv.org/abs/2312.11805) paper (Alizadeh et al., 2023)
for PocketREPL, enabling models **2× larger than available DRAM** to run on-device.

---

## Architecture

```
FlashInferenceBackend (ModelBackend protocol)
│
├── FlashWeightStore          ← Flash I/O engine
│   ├── 32-thread parallel reads (pread, POSIX-safe)
│   ├── 32 KiB minimum chunk size (paper's NVMe sweet spot)
│   ├── F_NOCACHE / F_RDAHEAD hints
│   └── Row-column bundling (2× throughput)
│
├── FlashNeuronCache          ← Sliding window DRAM cache
│   ├── Pre-allocated contiguous memory
│   ├── O(1) lookup (pointer array)
│   ├── O(1) eviction (swap-with-last)
│   └── Sliding window advance (last k tokens)
│
├── SparsityPredictor         ← Low-rank activation predictor
│   ├── 2-matmul forward pass: W_in [hidden→rank], W_out [rank→intermediate]
│   ├── Sigmoid threshold (default: 0.5)
│   └── Safety buffer (loads top-N extras for recall)
│
├── FlashInferenceEngine      ← Complete transformer forward pass
│   ├── RMSNorm / LayerNorm (Accelerate vDSP)
│   ├── Multi-head attention with KV cache (BLAS cblas_sgemv)
│   ├── RoPE position embeddings
│   ├── Sparse FFN (only active neurons computed)
│   ├── SwiGLU + ReLU / ReLU² activation support
│   └── Top-K / Top-P sampling
│
└── FlashModelConfig          ← Model metadata + file offsets
    └── FlashPackReader       ← Binary header parser
```

---

## Key Techniques (from the paper)

### 1. Activation Sparsity (Section 3.1)

ReLU-activated FFN layers have 90–97% sparsity:
- OPT-6.7B: 97% sparse FFN
- Falcon-7B (relufied): 95% sparse
- LLaMA-2 (FATReLU): 90% sparse

Only ~3–10% of FFN neuron weights are needed per token.

### 2. Sliding Window Cache (Section 3.1)

```
Token t-4  [A, C, F] active neurons
Token t-3  [B, C, G]
Token t-2  [A, D, G]
Token t-1  [B, E, H]    ← window (k=4)
Token t    [A, C, F]    ← mostly already in cache!

Flash reads needed = sagg(t) - sagg(t-1) ≈ 2.4% of FFN
```

### 3. Row-Column Bundling (Section 3.2)

For FFN neuron `j`, store:
```
[up_col_j: hidden floats][gate_col_j: hidden floats][down_row_j: hidden floats]
```

One `pread()` call fetches everything needed for neuron `j`:
- Old: 2 separate reads (1× up_col, 1× down_row)
- New: 1 bundled read → **2× larger chunk → 2× throughput**

### 4. Parallel I/O (Section 4.1)

```
Thread 0: pread(neuron_3)
Thread 1: pread(neuron_7)
...
Thread 31: pread(neuron_127)   ← 32 concurrent reads
```

Saturates NVMe controller's internal parallelism, amortizes latency-to-first-byte.

---

## FlashPack File Format

```
Offset  Size    Description
------  ------  -----------
0       8       Magic: "FLASHPK1"
8       8       uint64: JSON header length
16      N       UTF-8 JSON (FlashPackHeader)
16+N    ...     Weight data (described by header)

Per-layer layout:
  - Attention weights (Q, K, V, O, norms) → contiguous
  - Bundled FFN neurons: [up_col_j|gate_col_j|down_row_j] per neuron
  - Predictor weights (W_in, W_out) → optional
  - Neuron importance scores → optional float32 array
```

---

## Memory Layout for 7B LLaMA Model

| Component | Size | Location |
|-----------|------|----------|
| Attention weights (Q,K,V,O,norms) | ~4.6 GB | DRAM (always) |
| Token embeddings + LM head | ~0.5 GB | DRAM (always) |
| FFN neuron cache (25% of FFN) | ~2.3 GB | DRAM (sliding window) |
| Remaining FFN weights | ~6.6 GB | NVMe SSD |
| **Total DRAM** | **~7.4 GB** | (vs. 14 GB traditionally) |

---

## Performance Targets

| Device | SSD Bandwidth | Theoretical Max | Achievable (est.) |
|--------|---------------|-----------------|-------------------|
| M1 Max | 6 GB/s  | 11.5 tok/s | ~4–5 tok/s |
| M3 Max | 17.5 GB/s | 33 tok/s  | ~5–7 tok/s |
| M4 Max | ~22 GB/s  | ~42 tok/s  | ~8–10 tok/s |

Based on: paper reports 87 ms/token on M1 Max for OPT-6.7B with bundling+windowing.

---

## Workflow

### 1. Convert Model to FlashPack

```
FlashModelConverter.convert(
    ggufPath: "llama-2-7b-fatrelu.gguf",
    outputPath: "llama-2-7b.flashpack"
)
```

**Note:** The converter is currently a stub. You can use Python scripts to generate
FlashPack files — see `tools/convert_to_flashpack.py` (TODO).

### 2. Load and Use

```swift
let backend = FlashInferenceBackend()
let config = ModelConfiguration(modelPath: "llama-2-7b.flashpack", ...)
try await backend.load(configuration: config)

let request = GenerationRequest.generate(prompt: "Write a factorial function")
let response = try await backend.generate(request: request)
```

### 3. Monitor Performance

```swift
let cacheStats = await backend.cacheMetrics()
print("Cache hit rate: \(cacheStats?.formattedHitRate ?? "N/A")")

let ioStats = await backend.ioMetrics()
print("Flash read: \(ioStats?.totalMBRead ?? 0) MB")
```

---

## Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| `FlashModelConfig` | ✅ Complete | Model format spec |
| `FlashWeightStore` | ✅ Complete | Parallel I/O, F_NOCACHE, bundling |
| `FlashNeuronCache` | ✅ Complete | Sliding window, O(1) eviction |
| `SparsityPredictor` | ✅ Complete | Low-rank forward pass + fallbacks |
| `FlashMath` | ✅ Complete | BLAS + vDSP transformer math |
| `FlashInferenceEngine` | ✅ Complete | Full transformer forward pass |
| `FlashInferenceBackend` | ✅ Complete | ModelBackend protocol |
| `FlashInferenceStatusView` | ✅ Complete | Real-time metrics UI |
| Model converter | 🔨 Stub | Needs GGUF parser |
| Tokenizer integration | 🔨 Stub | Needs llama.cpp tokenizer wiring |
| Metal GPU shaders | 🔮 Future | For GPU-accelerated matrix ops |
| 2-bit quantization | 🔮 Future | Per flash-moe paper extension |

---

## References

- Paper: [LLM in a Flash](https://arxiv.org/abs/2312.11805) — Alizadeh et al., Apple, 2023
- Flash-MoE project: [danveloper/flash-moe](https://github.com/danveloper/flash-moe) — 397B MoE at 5.7 tok/s
- Flash-MoE key insight: removing the application-level LRU cache (let macOS cache) = 38% speedup
- ReLU sparsification: [Mirzadeh et al., 2023](https://arxiv.org/abs/2310.04564)
- FATReLU for LLaMA: [Song et al., 2024](https://arxiv.org/abs/2402.11682)

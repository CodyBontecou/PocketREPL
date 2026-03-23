//  FlashShaders.metal
//  PocketREPL — LLM in a Flash
//
//  GPU compute kernels for transformer inference.
//  Runs entirely on the Apple Neural Engine / GPU through Metal.
//
//  All buffers use MTLStorageModeShared (unified memory) so there are
//  zero-copy transfers between CPU and GPU on Apple Silicon.
//
//  Kernel naming convention:
//    flash_<operation>_<precision>
//  e.g.  flash_matvec_f32   — float32 matrix-vector multiply
//        flash_matvec_f16   — float16 matrix-vector multiply

#include <metal_stdlib>
using namespace metal;

// MARK: - Matrix-Vector Multiply (Dense)
//
// y = A × x  where A is [M × N] row-major, x is [N], y is [M]
//
// Used for: Q/K/V projections, output projection, LM head
//
// Each thread computes one element of y.
// Thread count: M (one per output row)

kernel void flash_matvec_f32(
    device const float* A      [[buffer(0)]],   // [M × N]
    device const float* x      [[buffer(1)]],   // [N]
    device float*       y      [[buffer(2)]],   // [M]
    constant uint&      M      [[buffer(3)]],
    constant uint&      N      [[buffer(4)]],
    uint gid                   [[thread_position_in_grid]]
) {
    if (gid >= M) return;

    float acc = 0.0f;
    const device float* row = A + gid * N;

    // Vectorised inner product using float4
    uint n4 = N / 4;
    const device float4* row4 = (const device float4*)row;
    const device float4* x4   = (const device float4*)x;

    for (uint j = 0; j < n4; ++j) {
        acc += dot(row4[j], x4[j]);
    }

    // Handle remainder
    for (uint j = n4 * 4; j < N; ++j) {
        acc += row[j] * x[j];
    }

    y[gid] = acc;
}

// Float16 variant — faster on ANE/GPU where F16 is natively accelerated
kernel void flash_matvec_f16(
    device const half* A       [[buffer(0)]],   // [M × N] f16
    device const half* x       [[buffer(1)]],   // [N] f16
    device float*      y       [[buffer(2)]],   // [M] f32 (accumulate in f32)
    constant uint&     M       [[buffer(3)]],
    constant uint&     N       [[buffer(4)]],
    uint gid                   [[thread_position_in_grid]]
) {
    if (gid >= M) return;

    float acc = 0.0f;
    const device half* row = A + gid * N;

    uint n4 = N / 4;
    const device half4* row4 = (const device half4*)row;
    const device half4* x4   = (const device half4*)x;

    for (uint j = 0; j < n4; ++j) {
        acc += (float)dot(row4[j], x4[j]);
    }
    for (uint j = n4 * 4; j < N; ++j) {
        acc += (float)(row[j]) * (float)(x[j]);
    }

    y[gid] = acc;
}

// MARK: - Sparse Down-Projection
//
// Accumulates the down-projection for only the active neurons:
//   output[i] += sum_j(activations[j] * down_rows[j * hiddenSize + i])
//
// down_rows is a packed buffer of [activeCount × hiddenSize] float values,
// where row j is the down-projection row for the j-th active neuron.
//
// One thread per output element (hiddenSize threads total).

kernel void flash_sparse_down_proj(
    device const float* down_rows   [[buffer(0)]],   // [activeCount × hiddenSize]
    device const float* activations [[buffer(1)]],   // [activeCount]
    device float*       output      [[buffer(2)]],   // [hiddenSize]
    constant uint&      activeCount [[buffer(3)]],
    constant uint&      hiddenSize  [[buffer(4)]],
    uint gid                        [[thread_position_in_grid]]
) {
    if (gid >= hiddenSize) return;

    float acc = 0.0f;
    for (uint j = 0; j < activeCount; ++j) {
        acc += activations[j] * down_rows[j * hiddenSize + gid];
    }

    output[gid] += acc;   // += to accumulate with existing residual
}

// Tiled variant with threadgroup memory — better cache utilisation for large activeCount
kernel void flash_sparse_down_proj_tiled(
    device const float* down_rows   [[buffer(0)]],   // [activeCount × hiddenSize]
    device const float* activations [[buffer(1)]],   // [activeCount]
    device float*       output      [[buffer(2)]],   // [hiddenSize]
    constant uint&      activeCount [[buffer(3)]],
    constant uint&      hiddenSize  [[buffer(4)]],
    threadgroup float*  tg_activations [[threadgroup(0)]],  // [TILE_SIZE]
    uint gid                           [[thread_position_in_grid]],
    uint lid                           [[thread_position_in_threadgroup]],
    uint tgSize                        [[threads_per_threadgroup]]
) {
    const uint TILE_SIZE = 32;
    float acc = 0.0f;

    for (uint tile = 0; tile < activeCount; tile += TILE_SIZE) {
        // Load a tile of activations into threadgroup memory
        if (lid < TILE_SIZE && tile + lid < activeCount) {
            tg_activations[lid] = activations[tile + lid];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Each thread accumulates for its output element
        uint tileLen = min(TILE_SIZE, activeCount - tile);
        if (gid < hiddenSize) {
            for (uint j = 0; j < tileLen; ++j) {
                acc += tg_activations[j] * down_rows[(tile + j) * hiddenSize + gid];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (gid < hiddenSize) {
        output[gid] += acc;
    }
}

// MARK: - Sparse Up-Projection
//
// Computes the up-projection for only the active neurons:
//   up_out[j] = dot(x, up_cols[j × hiddenSize : (j+1) × hiddenSize])
//
// where up_cols is a packed buffer of [activeCount × hiddenSize].
// One thread per active neuron.

kernel void flash_sparse_up_proj(
    device const float* up_cols     [[buffer(0)]],   // [activeCount × hiddenSize]
    device const float* x           [[buffer(1)]],   // [hiddenSize] input
    device float*       up_out      [[buffer(2)]],   // [activeCount] output
    constant uint&      activeCount [[buffer(3)]],
    constant uint&      hiddenSize  [[buffer(4)]],
    uint gid                        [[thread_position_in_grid]]
) {
    if (gid >= activeCount) return;

    const device float* col = up_cols + gid * hiddenSize;
    float acc = 0.0f;

    uint h4 = hiddenSize / 4;
    const device float4* col4 = (const device float4*)col;
    const device float4* x4   = (const device float4*)x;

    for (uint j = 0; j < h4; ++j) {
        acc += dot(col4[j], x4[j]);
    }
    for (uint j = h4 * 4; j < hiddenSize; ++j) {
        acc += col[j] * x[j];
    }

    up_out[gid] = acc;
}

// MARK: - SwiGLU Activation
//
// out[j] = SiLU(gate[j]) × up[j]
// SiLU(x) = x × sigmoid(x) = x / (1 + exp(-x))
//
// In-place on gate buffer; writes result to out buffer.

kernel void flash_swiglu(
    device float*       gate    [[buffer(0)]],   // [count] gate values (modified in-place)
    device const float* up      [[buffer(1)]],   // [count] up values
    device float*       out     [[buffer(2)]],   // [count] output
    constant uint&      count   [[buffer(3)]],
    uint gid                    [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    float g = gate[gid];
    float silu = g / (1.0f + exp(-g));      // SiLU(gate)
    out[gid] = silu * up[gid];
}

// MARK: - ReLU / ReLU² Activation

kernel void flash_relu(
    device float*   x     [[buffer(0)]],
    constant uint&  count [[buffer(1)]],
    uint gid              [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    x[gid] = max(0.0f, x[gid]);
}

kernel void flash_relu2(
    device float*   x     [[buffer(0)]],
    constant uint&  count [[buffer(1)]],
    uint gid              [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    float v = max(0.0f, x[gid]);
    x[gid] = v * v;
}

// MARK: - RMSNorm
//
// y[i] = (x[i] / RMS(x)) × weight[i]
// RMS(x) = sqrt(mean(x²) + eps)
//
// Pass 1: reduce to compute sum(x²) — done on CPU with Accelerate (fast enough)
// Pass 2: scale — this kernel applies scale + weight
//
// Actually we implement the full RMSNorm in one pass using a parallel reduction.
// Thread 0 of each threadgroup computes the final scale.

kernel void flash_rmsnorm(
    device const float* x       [[buffer(0)]],   // [size] input
    device const float* weight  [[buffer(1)]],   // [size] scale weight
    device float*       y       [[buffer(2)]],   // [size] output
    constant uint&      size    [[buffer(3)]],
    constant float&     eps     [[buffer(4)]],
    threadgroup float*  tg_sum  [[threadgroup(0)]],   // [1] shared sum
    uint gid                    [[thread_position_in_grid]],
    uint lid                    [[thread_position_in_threadgroup]],
    uint tgSize                 [[threads_per_threadgroup]]
) {
    // Phase 1: Parallel reduction for sum(x²)
    float local_sq = 0.0f;
    for (uint i = gid; i < size; i += tgSize) {
        float v = x[i];
        local_sq += v * v;
    }

    // Reduction within threadgroup
    tg_sum[lid] = local_sq;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) {
            tg_sum[lid] += tg_sum[lid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    float rms = sqrt(tg_sum[0] / float(size) + eps);
    float inv_rms = 1.0f / rms;

    // Phase 2: Apply scale
    for (uint i = gid; i < size; i += tgSize) {
        y[i] = (x[i] * inv_rms) * weight[i];
    }
}

// MARK: - Softmax
//
// Numerically-stable softmax over a single vector.
// Phase 1: find max (parallel reduction)
// Phase 2: exp(x - max) and sum (parallel reduction)
// Phase 3: divide by sum

kernel void flash_softmax(
    device float*   x     [[buffer(0)]],   // [size] input/output (in-place)
    constant uint&  size  [[buffer(1)]],
    threadgroup float* tg [[threadgroup(0)]],  // [tgSize] scratch
    uint gid              [[thread_position_in_grid]],
    uint lid              [[thread_position_in_threadgroup]],
    uint tgSize           [[threads_per_threadgroup]]
) {
    // Phase 1: find max
    float local_max = -INFINITY;
    for (uint i = gid; i < size; i += tgSize) {
        local_max = max(local_max, x[i]);
    }
    tg[lid] = local_max;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) tg[lid] = max(tg[lid], tg[lid + stride]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float global_max = tg[0];

    // Phase 2: exp and sum
    float local_sum = 0.0f;
    for (uint i = gid; i < size; i += tgSize) {
        float e = exp(x[i] - global_max);
        x[i] = e;
        local_sum += e;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    tg[lid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) tg[lid] += tg[lid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float global_sum = tg[0];

    // Phase 3: normalise
    float inv_sum = 1.0f / global_sum;
    for (uint i = gid; i < size; i += tgSize) {
        x[i] *= inv_sum;
    }
}

// MARK: - Scaled Dot-Product Attention (single query)
//
// scores[i] = dot(q, K[i]) × scale
// Followed by softmax (use flash_softmax kernel)
// attn_out = sum_i(scores[i] × V[i])
//
// q:      [headDim]
// K:      [seqLen × headDim]
// V:      [seqLen × headDim]
// scores: [seqLen] (output)
// scale:  1 / sqrt(headDim)

kernel void flash_attn_scores(
    device const float* q      [[buffer(0)]],   // [headDim]
    device const float* K      [[buffer(1)]],   // [seqLen × headDim]
    device float*       scores [[buffer(2)]],   // [seqLen] output
    constant uint&      seqLen [[buffer(3)]],
    constant uint&      headDim[[buffer(4)]],
    constant float&     scale  [[buffer(5)]],
    uint gid                   [[thread_position_in_grid]]
) {
    if (gid >= seqLen) return;

    const device float* k_i = K + gid * headDim;
    float acc = 0.0f;
    uint h4 = headDim / 4;
    const device float4* q4   = (const device float4*)q;
    const device float4* k4_i = (const device float4*)k_i;

    for (uint j = 0; j < h4; ++j) {
        acc += dot(q4[j], k4_i[j]);
    }
    for (uint j = h4 * 4; j < headDim; ++j) {
        acc += q[j] * k_i[j];
    }
    scores[gid] = acc * scale;
}

// Weighted sum of value vectors
kernel void flash_attn_weighted_sum(
    device const float* scores [[buffer(0)]],   // [seqLen] (softmax output)
    device const float* V      [[buffer(1)]],   // [seqLen × headDim]
    device float*       out    [[buffer(2)]],   // [headDim]
    constant uint&      seqLen [[buffer(3)]],
    constant uint&      headDim[[buffer(4)]],
    uint gid                   [[thread_position_in_grid]]
) {
    if (gid >= headDim) return;

    float acc = 0.0f;
    for (uint i = 0; i < seqLen; ++i) {
        acc += scores[i] * V[i * headDim + gid];
    }
    out[gid] = acc;
}

// MARK: - Q2 Dequantization Kernel
//
// Dequantizes a packed Q2 neuron buffer on the GPU.
// One thread per float value output.
//
// Input: Q2 packed bytes (blockSize=32, 2-byte scale + 8 bytes data per block)
// Output: float32 values

kernel void flash_dequantize_q2(
    device const uchar* packed    [[buffer(0)]],   // Q2 packed data
    device float*       output    [[buffer(1)]],   // float32 output
    constant uint&      count     [[buffer(2)]],   // total float values
    constant uint&      blockSize [[buffer(3)]],   // values per block (must be 32)
    uint gid                      [[thread_position_in_grid]]
) {
    if (gid >= count) return;

    const uint blockIdx = gid / blockSize;
    const uint posInBlock = gid % blockSize;
    const uint bytesPerBlock = 2 + blockSize / 4;  // 2 scale + 8 data bytes (for blockSize=32)
    const uint blockStart = blockIdx * bytesPerBlock;

    // Read scale (float16 at blockStart)
    const device half* scalePtr = (const device half*)(packed + blockStart);
    float scale = (float)(*scalePtr);

    // Read packed bits: 4 values per byte
    const uint byteIdx = posInBlock / 4;
    const uint bitShift = (posInBlock % 4) * 2;
    const uchar byteVal = packed[blockStart + 2 + byteIdx];
    const uint q = (byteVal >> bitShift) & 0x3;

    // Map quantised level to float:
    // 0 → -1.5, 1 → -0.5, 2 → +0.5, 3 → +1.5
    const float levels[4] = {-1.5f, -0.5f, 0.5f, 1.5f};
    output[gid] = levels[q] * scale;
}

// MARK: - RoPE Position Embedding
//
// Rotates consecutive pairs of head dimensions by a position-dependent angle.
// Applied in-place to query/key tensors.
//
// x[2i]   → x[2i]  × cos(θ) - x[2i+1] × sin(θ)
// x[2i+1] → x[2i]  × sin(θ) + x[2i+1] × cos(θ)
// θ_i = pos / theta^(2i/d)

kernel void flash_rope(
    device float*   x        [[buffer(0)]],   // [numHeads × headDim] in-place
    constant uint&  numHeads [[buffer(1)]],
    constant uint&  headDim  [[buffer(2)]],
    constant uint&  position [[buffer(3)]],
    constant float& theta    [[buffer(4)]],   // Base frequency (default 10000)
    uint gid                 [[thread_position_in_grid]]   // One thread per head
) {
    if (gid >= numHeads) return;

    device float* head = x + gid * headDim;
    uint halfDim = headDim / 2;
    float posF = float(position);

    for (uint i = 0; i < halfDim; ++i) {
        float freq = posF / pow(theta, float(2 * i) / float(headDim));
        float cosVal = cos(freq);
        float sinVal = sin(freq);
        float x0 = head[i * 2];
        float x1 = head[i * 2 + 1];
        head[i * 2]     = x0 * cosVal - x1 * sinVal;
        head[i * 2 + 1] = x0 * sinVal + x1 * cosVal;
    }
}

// MARK: - Vector Add (residual connection)

kernel void flash_vector_add(
    device float*       a     [[buffer(0)]],   // in-place: a += b
    device const float* b     [[buffer(1)]],
    constant uint&      count [[buffer(2)]],
    uint gid                  [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    a[gid] += b[gid];
}

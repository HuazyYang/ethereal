# Public point quantization implementation plan

Status: implemented; Windows acceptance recorded, 2026-10-19.

## Problem and intended behavior

Point-cloud currently performs GPU normalized-ushort quantization and decoding,
then reads the decoded data back and reuploads it through the public PointSet
converter. Introduce an additive public operator that consumes an authenticated
same-device PointSet and returns both packed ushort3 codes and a completed
PointSet of the actual GPU-decoded positions. Preserve ordinal correspondence,
position component count/W bits, and velocity/color attributes exactly. This
removes the application's decode/readback/reupload bridge while retaining the
public explicit record, caller submission/wait, and completion contract.

This is normalized unsigned 16-bit encoding, not IEEE half. Encoding is
`uint(saturate((position-minimum)/range)*65535)` and decoding is
`(float(code)/65535)*range+minimum`, with native backend binary32 arithmetic.
Codes may differ by one near a rounding boundary; independent tests must first
validate codes and then use those actual codes for decoded-value references.
No CPU reimplementation may replace the GPU result. Packed ushort3 records use
six bytes and a zero final halfword for odd counts.

## API and implementation

- A device-only factory owns separate offline encode/decode artifacts. No new
  execution layer, runtime compilation or backend SDK dependency is exposed.
- Preparation authenticates the original PointSet, validates explicit finite
  bounds or derives legacy padded bounds from actual converted extrema, and
  checks point, GPU-allocation, retained host-byte and buffer-count budgets.
- Record accepts one originating ticket on a caller-owned same-device non-copy
  command list; it records encode, decode and staging copies once. It never
  submits or waits. The caller must use an open command list.
- Completion after caller synchronization validates actual finite decoded XYZ
  and creates an authenticated canonical PointSet through a private same-binary
  seam. W and auxiliary attributes retain their original bits and association.
  A failed completion clears its interface output and remains retryable; a
  successful completion is one-use. Factory and source owners may be released.
- Expose immutable CPU codes after completion and a borrowed packed GPU buffer
  after recording, with explicit lifetime/ordering requirements. No topology
  mutation or gather is implicit. Empty input has a defined one-use empty result.
- Migrate point-cloud to this operator and its public PointSet inputs. Existing
  separate gather association/evaluation continues to select bins from original
  positions and distances from quantized positions.

## Verification

Validate descriptor ABI, exact artifact layouts, odd/empty/tail inputs, Float3
and Float4, W bit preservation, velocity/color transport, signed and padded
bounds, clamping, budgets, foreign/wrong/repeated tickets, retained sources and
retryable completion. Use independent normalized-code/decoded-value references,
all four Windows APIs, both graphics adapters, CUDA memory checking and installed
static/shared consumers. Rerun point-cloud analytic/full-asset/rendering fixtures
and compare preserved portable captures. Keep Linux, supported native multi-GPU
and performance acceptance separate; retain all reference implementations.

## Execution record

Implemented the additive device factory, validated encode/decode artifacts,
explicit record/completion ticket, authenticated decoded PointSet creation,
logical/GPU code views and budgets. Point-cloud uses public source conversion
and quantization directly; it retains original points for association and decoded
points for evaluation. Diagnostic tests borrow actual public codes, validate them
independently, then use them for the gather reference. Production no longer calls
the retained conversion/quantization/decode helpers.

Evidence is under `build/m5-public-quantize` (initial integration logs under
`build/point-quantize-integration-*`):

- ABI/default/version/output checks and all four GPU quantization tests pass 5/5.
  GPU tests cover Float3/Float4, empty/odd/tail counts, explicit/padded bounds,
  clamping, exact W/attribute transport, CPU/GPU coherence, exact budgets,
  authentication, wrong factory, one-use lifetime and altered artifacts.
- Initial quantization plus analytic/full-asset/app tests pass 16/16. Rendering
  and RT clipping fixtures pass 10/10.
- Quantization and analytic reconstruction pass native validation on NVIDIA and
  AMD through D3D11/D3D12/Vulkan. Both CUDA memchecks report zero errors.
- Standalone installed static and shared API consumers pass 2/2 each, including
  released source/operator lifetime and actual-code decoded results. Both link
  the shared NVRHI runtime. Consumer CUDA Toolkit discovery is disabled.
- The graphics-only/CUDA-discovery-disabled build and acceptance matrix pass.
- Preserved portable capture comparison is recorded in `image-comparison.json`.
  Vulkan compute is identical. D3D11/D3D12/CUDA compute change six pixels by one
  byte. D3D12 RT changes eight pixels and CUDA RT eleven, maximum byte delta12;
  Vulkan RT changes one pixel by one byte. Explicit public conversion now has
  its defined binary32 operation order; independent conversion/reconstruction
  references pass. Universal image bit identity is not claimed.

The full-suite counts in the earlier checkpoint remain historical; this slice
ran focused API/sample and package acceptance. Linux, supported native multi-GPU,
broad performance/visual acceptance and reference retirement remain open.
Weighted inverse-distance color and remaining deposition/consumer work continue.

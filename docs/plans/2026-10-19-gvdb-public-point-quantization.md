# Public point quantization implementation plan

Status: authorized implementation continuation, 2026-10-19.

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

API descriptors and offline encode/decode kernels have been drafted; the ticket
implementation and validation are in progress. This plan does not claim weighted inverse-distance color
acceptance or completion of the mega project.

# M5 public regional downsample checkpoint

Status: implemented and validated on Windows, 2026-10-19. The mega project remains in progress.

Samples `dc3a118` adds the device-only public `IGVDBDownsample` operation, copied dense Float32 source preparation, authenticated one-use recording/completion tickets, offline artifacts and static/shared package consumers. No existing public interface changes. See the [contract](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiDownsampleApi.md). The caller records, submits and waits; GPU serial sums and counts feed a final CPU double division, preserving exact activation-threshold decisions. This explicit query readback is part of the contract and is not a cross-API interop fallback.

Thirty-three independent numerical cases cover two transformed endpoints, reflection, shear, truncation/clamping, X-fast accumulation, remap order, threshold neighbors, IEEE samples and adjacent values around integer boundaries. Descriptor, work/allocation budget, empty, authentication, lifetime and malformed-reflection cases are included.

Two adapter differences required production corrections. AMD D3D11/D3D12 approximate division placed an exact endpoint below its integer boundary. The shader now computes positive binary32 endpoint division by an integer denominator with exact quotient/remainder rounding; it does not snap coordinates or bias by epsilon. AMD Vulkan default rounding also changed cancellation-heavy sums. The kernel explicitly requests RTE32 through the pinned Slang SPIR-V assembly hook. All four target artifacts compile. Per-sample remap division retains the documented hardware arithmetic accuracy.

NVRHI `689f89e` checks declared SPIR-V RTE/RTZ execution modes against the physical device float-control properties before creating shader modules/libraries. Unsupported widths/modes fail explicitly. The bounded, unaligned-safe CPU parser is not a full SPIR-V validator and does not alter default rounding or public interface layouts. See [runtime guard](../../ethereal-nvrhi/docs/spirv-float-controls.md).

## Verification

- Final complete build/test matrices pass **329/329 in 206.33 seconds** and **248/248 in 167.41 seconds** with CUDA discovery disabled. No skipped tests. Logs: `build/m5-downsample-final-{full,graphics}-tests.log`; corresponding JUnit XML is in each build directory. Both final builds pass after transient Windows linker file locks were resolved by reducing concurrency; retry build logs retain the evidence.
- NVIDIA RTX 4050 and AMD Radeon 780M each pass D3D11/D3D12/Vulkan with explicit adapter selection and native validation: `build/m5-downsample-api/{dx11,dx12,vk}-adapter{0,1}-rte-final-native.log`. Final aggregate Vulkan guard paths pass on both adapters: `vk-adapter{0,1}-guarded-native.log`. Adapter identities are printed; ordinal identity is not assumed across APIs.
- CUDA passes the same numerical suite under Compute Sanitizer with zero errors: `build/m5-downsample-api/cuda-rte-final-memcheck{,-console}.log`.
- Shared/static SDK and installed compiler/CUDA-discovery-disabled CPU consumers pass. Final installed CUDA consumers pass **1/1 each**, in **1.80/0.18 seconds**: `build/m5-downsample/installed-{shared,static}-final-cuda.log`. Final source/document installs were refreshed after RTE32 changes.
- The retained 100-entry inventory now records **28 owned-validated, 12 sample-validated, 30 portable-foundation, 24 partial and 6 pending** roles. These counts are not project completion percentages and authorize no reference retirement.

The complete matrices above describe the committed downsample checkpoint and the preceding resample consumer. The next uncommitted resample ownership migration has separate acceptance. Linux, native supported multi-GPU routes, remaining operators/consumers, broader interactive/reference/performance acceptance and reference retirement remain open.

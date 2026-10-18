# M5 resample consumer ownership checkpoint

Status: implemented and validated on Windows, 2026-10-19. The mega project remains in progress.

Samples `643cdaa` migrates the resample application to the public device-only downsample query, host topology/halo operations, owner generation/publication, and owned resample operator. A retained CPU input replaces the persistent dense GPU source; there is no persistent PackedVolume, SlangVolume or duplicate typed atlas. Standard raw snapshot viewer paths cover all viewing modes, with topology overlays from public host nodes. The production resample artifact no longer depends on BUILD_TESTING. See the [sample contract](../../ethereal-samples/src/gvdb_samples/samples/resample/README.md).

Each rebuild constructs a fresh owner, publishes initial scalar storage, then publishes resampled values, all on caller-owned commands submitted in queue order. Only the complete visible state is replaced. Query and verification readbacks submit/wait explicitly; publication itself is not completion. Preparation failure preserves the old visible state; submitted device failure is not an atomic rollback. The first integration test caught an incorrect inclusive maximum passed to computeExtents; the adapter now passes the API's half-open destination bound.

## Verification

- Final complete matrices pass **329/329 in 200.11 seconds** and **248/248 in 161.61 seconds** (CUDA discovery disabled), with no skipped tests. Both full builds pass. Logs: `build/m5-owned-resample/final-{full,graphics}-{build,tests}.log`; JUnit XML is in each build directory.
- Affected analytic/asset suites pass **8/8 in 7.31 seconds** and **6/6 in 5.22 seconds**. Independent references verify every transformed atlas/apron voxel, coarse averages, complete masks and leaf counts. The head asset retains **4,096 dense / 2,472 sparse / 2,997 halo** leaves. Exact 0.05 equality remains inactive.
- New lifecycle cases verify copied CPU source, old snapshot bytes across sparse/halo rebuilds and owner release, and canonical empty sparse/halo publication.
- Explicit NVIDIA and AMD adapter runs pass analytic and real-asset native validation on D3D11/D3D12/Vulkan. Bounded two-frame topology windows pass all three APIs. Logs: `build/m5-owned-resample/{dx11,dx12,vk}-adapter{0,1}-native-{analytic,head}.log` and `*-native-window.log`; mappings are corroborated by the explicit downsample adapter logs from the preceding checkpoint.
- Analytic and complete head CUDA Compute Sanitizer runs report **zero errors**: `cuda-{analytic,head}-memcheck.log`.
- Tests-disabled/CUDA-discovery-disabled production build/run passes and matches the explicit AMD DX11 compute image exactly: `production-{configure,build,run}.log`, `production.png`, `image-comparison.json`.
- Compared with preserved previous-portable images, all four aggregate outputs differ by at most one byte in two or three RGB pixels. This is bounded previous-portable comparison, not handwritten CUDA screenshot parity. The independent data references match exactly.

The full matrices describe the committed resample migration and the preceding 3d-print consumer. 3d-print ownership is the next uncommitted slice. The public mesh voxelization operator, scatter, weighted ushort gathering, remaining consumer ownership, Linux, supported native multi-GPU routes, broader interactive/reference/performance acceptance and reference retirement remain open. The retained 100-entry inventory remains 28 owned-validated, 12 sample-validated, 30 portable-foundation, 24 partial and 6 pending roles; no sources are retired.

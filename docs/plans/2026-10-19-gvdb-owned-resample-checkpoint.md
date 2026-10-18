# M5 owned resample checkpoint

Status: implemented and validated on Windows, 2026-10-19. The mega project remains in progress.

Samples `1b6a26c` adds the public `IGVDBResample` factory, private raw-atlas implementation, offline Slang shader, and static/shared package consumers. Existing interfaces and vtables remain unchanged. See the [public contract](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiResampleApi.md).

Preparation copies the used dense Float32 source bytes and allocates a fresh selected R32_FLOAT channel. The existing generation ticket records and publishes through caller-owned commands. Other channels and topology remain shared, retained snapshots keep their old data, and failed or stale operations do not partially publish.

Affine rows transform integer world voxel coordinates, including active aprons, and source indices truncate toward zero. Outside coordinates preserve exact old bits by default, including signed zero and NaN payloads; explicit background replacement is also available. Nonfinite and out-of-int32 coordinates are classified before integer conversion. Source NaN/infinity values follow remap arithmetic. Unused slots are zero. Covering coordinate-zero atlas planes corrects a retained launch omission and is explicitly distinguished from legacy byte identity.

## Verification

- Final aggregate ABI and four-backend suite: **5/5**, 3.10 seconds. Logs/JUnit: `build/m5-resample-final-tests.log/xml`.
- Graphics-only with CUDA Toolkit discovery disabled: **4/4**, 1.63 seconds. Log: `build/m5-resample-final-graphics-tests.log`; JUnit: `build/graphics-only/m5-resample-final-tests.xml`.
- Final rebuild logs: `build/m5-resample-final-{configure,build}.log` and `build/m5-resample-final-graphics-{configure,build}.log`.
- Independent native D3D11/D3D12/Vulkan validation passes and CUDA Compute Sanitizer reports zero errors. Logs: `build/m5-resample-api/{dx11,dx12,vk}-native.log` and `cuda-memcheck.log`. The final fixture includes actual dense NaN and signed infinity inputs, exact outside bit preservation, signed/reversed sparse slots, transforms, remap, extreme coordinates, deep-copy behavior, channel31, budgets, stale/foreign tickets and owner-free execution.
- Static/shared SDK builds and installs pass with compiler/CUDA discovery disabled. ABI and installed concrete-linkage checks pass for both variants; installed CUDA consumers pass separately in 1.83/0.38 seconds. Logs: `build/m5-contract/resample-api-{shared,static}-*.log` and `resample-installed-{shared,static}-*.log`.
- The retained CUDA inventory still matches all 100 explicit entries and existing replacement paths. Resample moves to owned-validated: 25 owned-validated, 12 sample-validated, 33 portable-foundation, 24 partial and 6 pending. These describe roles, not a project completion percentage or reference-retirement authorization.

These runs cover the newly changed resample slice. The previous affected point/reduction/custom suite remains 75/75 and graphics-only 58/58; the last full project matrix remains 274/274 and graphics-only 208/208.

## Remaining work

Depth-map snapshot adoption is in progress and is not accepted by this checkpoint. Ordinary public density/level-set gathering is next: authenticated point sets, stable CPU bins from completed conversion bytes, raw GPU streams, and explicit selected-channel publication. Normalized-ushort inverse-distance color requires a separately defined zero-distance/packing contract. Regional downsampling, scatter, voxelization and remaining consumer ownership continue. Linux, real multi-GPU routes, broader interactive/legacy visual and performance acceptance, and reference retirement remain open.

# M5 separate gather evaluation and owned point-cloud checkpoint

Status: implemented and validated on Windows, 2026-10-19. The mega project remains in progress.

Samples commit: `ab85dff`.

## Objective and contract

Point-cloud must retain the associations made before normalized-ushort quantization. The new queryable `IGVDBGatherEvaluation : IGVDBGather` adds an 80-byte `GatherEvaluationDesc`: embedded `request.points` determines cell membership, while `evaluationPoints` determines distances and optional colors. Both are completed authenticated same-device PointSets with equal counts. The caller guarantees ordinal correspondence. Translation applies to both; nonempty atlas preparation rejects translated nonfinite coordinates in either stream. Budgets count association visits/pairs. The existing factory, interface vtable and 64-byte request remain unchanged; ordinary preparation uses the same set in both roles. No new shader ABI or implicit GPU operation is introduced.

Point-cloud now rebuilds through public host activation, owned generation, gather evaluation, apron and filter APIs. Signed-axis support and leaf16 topology are preserved. Each ordinal is quantized once on the GPU using the existing expression, with original positions retained for binning. The application explicitly reads decoded results and uploads copied public PointSets; operator preparation never reads back or submits. A fresh owner makes both early and late failures preserve the prior visible snapshot. Tests retain old snapshot storage across owner replacement and reject a late invalid filter iteration request.

The standard preview uses the existing raw owned level-set surface renderer with missing-cell value 3. The topology overlay uses the public host pool; an empty scene retains an empty public publication. Diagnostic topology/atlas readback is explicit and is not a second rendering authority. Legacy helpers/shaders remain available.

The mixed mesh/volume renderer accepts retained public snapshots directly, adds raw scalar resource arrays alongside its structured path, preserves byte ranges for all topology/channel views, and checks device identity. Tests cover raw/structured surface/level-set/empty-skip modes, mixed array endpoints and nonzero view bases. Raw bases must align to 16 bytes and level views to `sizeof(LevelInfo)`.

## Implementation findings and deviations

An initial nonzero-range fixture used raw offsets 20 and 8. It passed Vulkan/CUDA but caused D3D12 device removal. These violate the [Direct3D raw view alignment requirement](https://microsoft.github.io/DirectX-Specs/d3d/D3D12RevisedCreateViews.html). The renderer now rejects them before binding and the fixture uses valid nonzero bases. It passes explicit NVIDIA D3D12 native validation. This was a new fixture/renderer validation defect, not evidence that valid public snapshots failed.

The first migrated compute preview reached the generic viewer, which rejects a nonzero missing level-set scalar. Connecting `OwnedVolumeSurface` preserves the intended background of 3. No alternate scalar equation or epsilon was introduced.

This checkpoint does not implement a public quantization stage or inverse-distance normalized-ushort color gathering. Explicit application readback remains visible in the reconstruction sequence. The retained point-cloud requests no color channel, so its acceptance cannot promote that separate weighted-color role.

## Verification

Logs are under `build/m5-owned-point-cloud`.

- Gather ABI and all four GPU fixtures pass, including independent cross-boundary association/evaluation/color references, count/authentication/output validation, budgets and resource lifetime.
- All six NVIDIA RTX4050/AMD Radeon780M graphics API/adapter combinations pass gather, point-cloud analytic reconstruction and app controls with native validation: `gather-*`, `reconstruction-*`, `app-*-native.log`.
- The mixed raw/structured RT fixture passes both adapters on D3D12/Vulkan with native validation: `rt-*-native.log`.
- Installed static and shared API consumers each pass 2/2, including querying the extension and recording after PointSet release. Both use the installed shared NVRHI runtime; CUDA Toolkit discovery is disabled.
- CUDA memory checks for gather, analytic reconstruction and raw/structured mixed RT report zero errors: `*-cuda-memcheck.log`.
- All four compute captures exactly match preserved previous-portable images. D3D12 RT is identical; CUDA changes two color-channel bytes by one and Vulkan one byte by one. This is not a universal RT bit-identity or legacy-image parity claim.
- Full matrices pass **334/334 in 226.93 seconds** and **252/252 in 219.16 seconds**, without failures or skips: `full-tests.log`, `full-graphics-tests.log`. JUnit: `build/m5-owned-point-cloud-full-tests.xml` and `build/graphics-only/m5-owned-point-cloud-full-tests.xml`.
- Tests-disabled/CUDA-discovery-disabled production passes explicit AMD DX11 native validation and exactly matches the previous DX11 compute capture: `production-{configure,build,run}.log`, `image-comparison.json`.
- Bounded two-frame compute windows pass all three graphics APIs on explicit NVIDIA with native validation: `window-{dx11,dx12,vk}.log`. These are bounded functional checks, not broad interactive/performance acceptance.

## Remaining work

The inventory stays at 100 retained CUDA entries, with 31 owned-validated, 12 sample-validated, 27 portable-foundation, 24 partial and 6 pending roles. Remaining public quantization/weighted-color, deposition, other ownership consumers, Linux, supported native multi-GPU routes, broader interactive/visual/performance acceptance and reference retirement are still open. No reference retirement is authorized.

# Mixed RT reference investigation

Status: implementation and focused Windows validation, 2026-10-20. Full project
acceptance remains open; this record does not retire the reference.

Fresh 1024x768, eight-sample Lucy/explosion captures exposed a level-set sampling
error and incomplete hierarchy-entry bias in the shared RT shader. Level sets now
start on the unrounded brick entry, matching `rayLevelSetBrick`; surface/deep
sampling retains the direct-step wavefront. All modes inherit epsilon from global
entry and ancestor descents. Zero gradients are resolved in world space so the
fallback remains camera-facing under nonuniform transforms.

The unchanged legacy level-set image is nearly black because `normalize(0)`
creates NaN attributes, and its nominally zero front offset propagates NaN into
the shading position. A diagnostic CUDA copy changed only:

```cpp
const float3 fhp = frontOfs == 0.f ? hitW :
    hitW + optixTransformVectorFromObjectToWorldSpace(nObj * frontOfs);
```

The diagnostic was compiled with the reference's compute_75, fast-math and OptiX
settings. Its PTX was installed only for the diagnostic capture and restored in
`finally`; retained source files were never changed. It confirms the finite
level-set appearance. It is separate evidence, not an unchanged reference pass.

Current CUDA image errors in byte values (other APIs are close):

| Mode/reference | Mean RGB | Filtered mean RGB | Filtered volume ROI mean |
| --- | ---: | ---: | ---: |
| Deep/unchanged | 1.1830 | 0.5244 | 1.1457 |
| Trilinear/unchanged | 2.0286 | 0.5281 | 1.1763 |
| Empty-skip/unchanged | 2.0917 | 1.1543 | 4.6808 |
| Level-set/unchanged | 6.8589 | 6.4103 | 33.9670 |
| Level-set/finite-offset diagnostic | 1.8944 | 0.6340 | 1.7786 |

Filtering uses Gaussian sigma four. The fixed ROI is x=[500,880), y=[220,590).
The existing per-pixel RNG, accumulation and half-pixel camera corrections remain
explicit. Empty-skip at 64 samples still has filtered mean error 1.1423; its
remaining difference cannot be described solely as eight-sample noise. CUDA versus
DX12 full-frame means are 0.000087/0.00169/0.07045/0.06872 for the four modes;
secondary-ray boundary decisions can amplify small coordinate differences.
Broader visual acceptance, including the remaining empty-skip difference, stays open.

The expanded analytic suite checks unrounded entries, two descent biases,
near-plane clipping, and finite zero-gradient lighting under nonuniform scale.
All three RT backend suites pass. Native DX12/Vulkan validation passes on both
RTX4050 and Radeon780M; CUDA Compute Sanitizer reports zero errors. The 425/320
full matrices predate this shader change and must be rerun at the final checkpoint.

Reproduce captures with the committed `sample-utils/CompareLegacySceneRT.py`.
Local images, logs, diagnostic source/PTX and measurements are in
`build/acceptance/mixed-reference`; the diagnostic driver is
`build/acceptance/diagnose-normal.ps1`. These local artifacts are not packaged.

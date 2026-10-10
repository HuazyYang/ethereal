# EPM - Ethereal Package Manager

`ethereal-nvrhi/cmake/EPM.cmake` is a CPM.cmake-style, configure-time package
manager. It resolves everything the build needs from outside a project's own sources
without selecting or invoking an external package manager. The argument reference is the
header comment of the module; this page records the design and what it replaces.

## One file

There is exactly one copy, in nvrhi (the deepest project that needs it). Every project
includes it by path; including it again is a no-op:

```cmake
include("${CMAKE_CURRENT_LIST_DIR}/cmake/EPM.cmake")                                  # nvrhi
include("${CMAKE_CURRENT_SOURCE_DIR}/ethereal-nvrhi/cmake/EPM.cmake")                    # aggregate
include("${CMAKE_CURRENT_SOURCE_DIR}/../ethereal-nvrhi/cmake/EPM.cmake")                 # donut
```

## API

| Function | Purpose |
| --- | --- |
| `epm_add_package(...)` | code built as part of the build: installed package, submodule, or fetched from git/URL; `gh:user/repo@tag` shorthand |
| `epm_declare_package(...)` | remember arguments; `epm_add_package(NAME x)` / `epm_add_package(x)` uses them |
| `epm_find_package(...)` | the arguments of `epm_add_package`, but `find_package` is always tried first |
| `epm_add_asset(...)` | files that are only downloaded or checked out: SDKs, media, scenes, archives, git trees |
| `epm_use_package_lock(file)` / `epm_write_package_lock(file)` | pin fetched packages to exact commits / hashes |
| `epm_print_summary()` | what was resolved, and from where |

`epm_add_package`, `epm_find_package` and `epm_add_asset` share one engine; an asset is a
`DOWNLOAD_ONLY` package that never looks for an installed copy and also reports
`<NAME>_DIR` and `<NAME>_FILE`.

## Behaviour that goes beyond CPM

| Need | Mechanism |
| --- | --- |
| Share downloads between build trees and clean rebuilds | `EPM_SOURCE_CACHE` (default `<build>/_epm/src`), keyed by a hash of everything that changes the content |
| Reproducible builds | `-DEPM_UPDATE_LOCK_FILE=<file>` writes exact commits / hashes at the end of configure; `epm_use_package_lock(<file>)` applies them. A download that had no hash gets the SHA256 of what was fetched, so the lock makes it verified. |
| Local changes to a dependency | `PATCHES` (applied with `git apply`, part of the cache key); `-DEPM_<NAME>_SOURCE=<dir>` swaps in a working copy |
| Flaky or blocked network | `EPM_URL_REWRITE` mirrors (`prefix=replacement`), download retries, `EPM_OFFLINE` |
| CI | every switch can be an environment variable instead of a `-D` option |
| Integrity | URL downloads need `URL_HASH` (any algorithm `file()` knows, e.g. MD5 for Aftermath); `ALLOW_UNVERIFIED` is explicit |
| Fixed in-tree locations (`DONUT_*_FETCH_DIR`) | `FETCH_DIR` / `DESTINATION`; content EPM did not create there is used as it is and never modified |
| Sparse checkouts, submodules of a fetched repository | `SPARSE_PATHS`, `GIT_SUBMODULES` |
| Header-only libraries that vcpkg installs without a CMake package (stb, cgltf) | `FIND_HEADER <file>` (`find_path`), `<NAME>_INCLUDE_DIR` |
| An installed copy that is unusable (a vcpkg imgui without the GLFW backend) | `FIND_ACCEPT <function>` rejects it and EPM falls back to the source |
| Installed targets visible in every directory | found imported targets are made global (`CMAKE_FIND_PACKAGE_TARGETS_GLOBAL`), like built ones |
| Archives without an extension (NuGet) | `FILENAME agility.zip` |
| Uninitialised git submodules (empty directories) | `SOURCE_DIR` rejects them with the `git submodule update` hint |
| Same package requested twice | first wins; a warning if the second wants a newer `VERSION` or another source, an error with `EPM_STRICT` |
| Inspection | `EPM_DRY_RUN`, `EPM_SHOW_SUMMARY` |

## Survey of current usage (2026-10-08)

| Usage in the tree | How EPM covers it |
| --- | --- |
| aggregate: `ethereal-donut`, `ethereal-nvrhi`, `ethereal-samples` submodules | `epm_add_package(... SOURCE_DIR ...)` (done) |
| nvrhi: Vulkan-Headers, DirectX-Headers (installed or fetched, version range) | `epm_add_package(... PACKAGE ... FIND_PACKAGE_ARGUMENTS CONFIG GIT_REPOSITORY ...)` (done) |
| nvrhi: RTXMU (git, `NVRHI_RTXMU_FETCH_DIR`, `RTXMU_WITH_*`) | `epm_add_package` with `FETCH_DIR`, `OPTIONS` |
| donut thirdparty: zstd (git, `build/cmake`, options) | `epm_add_package` with `SOURCE_SUBDIR`, `OPTIONS` |
| donut thirdparty: glfw, imgui (vcpkg or fetched) | `epm_add_package(... PACKAGE ... GIT_TAG ...)`, imgui with `FIND_ACCEPT` |
| donut thirdparty: stb, cgltf (header-only; vcpkg or fetched), shader-tool (git submodule) | `FIND_HEADER` + `DOWNLOAD_ONLY`; `SOURCE_DIR ... TARGETS ...` |
| donut: DLSS (git commit, fixed dir) | `epm_add_asset` git + `DESTINATION` |
| donut: Streamline (URL + SHA256, fixed dir; or local search paths) | `epm_add_asset` URL + `DESTINATION`; the search-path branch stays a plain `find_package` |
| nvrhi: Aftermath (URL + MD5, per-platform URL, fixed dir; or local search paths) | `epm_add_asset` with `URL_HASH MD5=` + `DESTINATION` |
| donut: D3D12 Agility SDK (NuGet URL without extension, no hash, or a local path) | `epm_add_asset` with `FILENAME x.zip` and `ALLOW_UNVERIFIED` |
| nv_asteroids: sqlite amalgamation zip, lz4 source | `epm_add_asset` (or `epm_add_package ... DOWNLOAD_ONLY`) |
| nv_asteroids: PhysX / assimp / HBAO+ sparse header checkouts | `epm_add_asset` git + `SPARSE_PATHS` (replaces `nv_asteroids_fetch_sparse`) |
| samples: `media/glTF-Sample-Assets` (a manual clone) | `epm_add_asset` git + `DESTINATION`; an existing clone is left alone |
| OptiX (optional, custom Find module) | `epm_add_package(NAME OptiX PACKAGE OptiX FIND_PACKAGE_ARGUMENTS MODULE OPTIONAL)` |

Deliberately not covered: toolchain and system lookups that are plain `find_package` calls
(CUDAToolkit, Python3, Git, Threads, `lib.exe`) and the original Asteroids install
(`NV_ASTEROIDS_ORIGINAL_DIR`: `media.db` and its DLLs), which cannot be downloaded.

## Differences from CPM worth knowing

- `find_package` is tried when a package gives `PACKAGE` or `FIND_PACKAGE_ARGUMENTS`, when the
  call is `epm_find_package`, or when `EPM_USE_LOCAL_PACKAGES=ON` (default OFF, as in CPM).
- `SOURCE_DIR` means "a source tree that is already in this repository" (a submodule), as in
  CPM. Fetching into a fixed directory is `FETCH_DIR`.
- `OPTIONS` accepts `KEY VALUE` (CPM) and `KEY=VALUE`; values are forced cache entries, so
  they also reach packages that call `option()` under an old policy.
- A package without a `CMakeLists.txt` is not an error: its sources are made available and
  nothing is added.

## Migration status

Everything below resolves through EPM. `ethereal-nvrhi` is a git submodule of the aggregate (a sibling of donut), `thirdparty/shader-tool` remains a git submodule of donut, and samples have none.

| Project | Resolved through EPM |
| --- | --- |
| aggregate | `ethereal-donut`, `ethereal-nvrhi`, `ethereal-samples` (submodules of the aggregate) |
| nvrhi | Vulkan-Headers, DirectX-Headers, RTXMU, Aftermath, NVAPI (an SDK on `NVAPI_SEARCH_PATHS` or in `<source>/nvapi`, else NVIDIA's repository at a pinned commit) |
| donut | `nvrhi` (the aggregate's `ethereal-nvrhi`, a sibling of donut) and `shader-tool` (a git submodule of donut); glfw, imgui, stb, cgltf (the installed vcpkg copy when it is usable, else fetched at a pinned commit); zstd (for KTX2), DLSS, Streamline, the D3D12 Agility SDK script |
| samples | Agility SDK (version-pinned SHA256), nv_asteroids: sqlite3, lz4, and the sparse PhysX / assimp / HBAO+ header checkouts |

donut's glfw, imgui, stb and cgltf are looked up in vcpkg first (`glfw3`; `imgui` only if it has the GLFW backend
and is recent enough; `stb_image.h`; `cgltf.h`) and otherwise fetched, at the commit the old submodules pointed
at, into EPM's source directory (`EPM_SOURCE_CACHE`, default `<build>/_epm/src`). To use a working copy
instead, pass `-DEPM_<NAME>_SOURCE=<dir>`; to ignore vcpkg, `-DEPM_DOWNLOAD_<NAME>=ON`.

Not migrated: the plain `find_package` calls listed above (CUDAToolkit, Python3, Threads,
`lib.exe`) and the original Asteroids install (`NV_ASTEROIDS_ORIGINAL_DIR`). Requires CMake 3.21
or newer.

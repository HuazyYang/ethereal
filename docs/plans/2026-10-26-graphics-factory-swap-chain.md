# Move DeviceManager's graphics-API code into nvrhi (per-backend IGraphicsFactory + IGraphicsSwapChain)

- Status: Approved
- Date: 2026-10-26
- Branch: `graphics-factory` in the aggregate, `ethereal-nvrhi`, `ethereal-donut` and `ethereal-samples`
- ADR: [`ethereal-nvrhi/doc/adr/0014-per-backend-graphics-factories-and-swap-chains.md`](../../ethereal-nvrhi/doc/adr/0014-per-backend-graphics-factories-and-swap-chains.md)
- Archived at `docs/plans/2026-10-26-graphics-factory-swap-chain.md`. The maintained copy, with the *Step N as built* notes, is in `ethereal-nvrhi/doc/plans/`.

## Context

donut's `DeviceManager_DX11/DX12/VK.cpp` (~2500 lines) holds all native graphics-API work: the DXGI factory, the
VkInstance and its debug callbacks, adapter/physical-device selection, native device and queue creation, the swap
chain, and frame pacing. nvrhi's `IGraphicsFactory` (ADR 0010) only wraps native devices that the caller created.
Applications that don't use donut have to repeat all of this. They also have to link `d3d11/d3d12/dxgi`, and export
`D3D12SDKVersion` from the exe to get the Agility SDK.

Goal: nvrhi gets one graphics factory per backend. Each factory:
1. creates its API objects: the DXGI factory, or the VkInstance;
2. enumerates and selects the adapter (an `IDXGIAdapter*` or a `VkPhysicalDevice`);
3. loads the D3D DLLs (Agility SDK included) or the Vulkan entry points at run time;
4. creates the native device and queues inside its own creation function;
5. creates the backend's swap chain, which presents to a window and synchronizes the command queue with
   presentation.

donut's DeviceManager keeps the window, the GLFW, the render passes and the frame loop, and becomes a thin client of
the factory.

**User decisions (2026-10-26, do not re-litigate):**
- **The factory splits by backend.**
  - `nvrhi::IGraphicsFactory` is the common base interface.
  - `nvrhi::d3d11::IGraphicsFactory`, `nvrhi::d3d12::IGraphicsFactory`, `nvrhi::vulkan::IGraphicsFactory` (and
    `nvrhi::cuda::IGraphicsFactory`) derive from it.
  - Each creates its backend's `IDevice` and `IGraphicsSwapChain`.
- **`nvrhi::IGraphicsSwapChain` lives in the `nvrhi` namespace.** Each backend has its own implementation and its own
  derived interface (`d3d12::IGraphicsSwapChain`, ...).
- **Device creation takes a per-backend `DeviceCreationDesc` with no native objects.** It holds no
  `ID3D11Device*`/context, `ID3D12Device*`/`ID3D12CommandQueue*`, `VkInstance`, `VkPhysicalDevice`, `VkDevice` or
  `VkQueue`. The creation function creates them itself, fills the existing `DeviceDesc` internally, and runs today's
  backend path. The existing `DeviceDesc` structs are unchanged.
- **No common `nvrhi::GraphicsFactoryDesc`.** Each backend has its own `<backend>::GraphicsFactoryDesc` and its own
  creation function for its factory.
- **No `IGraphicsAdapter`.** The factory reuses DeviceManager's current adapter-selection logic (DXGI: `adapterIndex`,
  where -1 means 0; Vulkan: the `pickPhysicalDevice` rules).
- **No `WindowSystem` enum.** The swap chain takes the native window handle directly.
- **The swap chain's per-frame entry point is `beginFrame`.** D3D12 waits on the current frame fence's sync point.
  Vulkan acquires the next image. CUDA waits for the in-flight stream work.
- **nvrhi owns the global Vulkan-Hpp default dispatcher,** and the Vulkan factory initializes it.
- **The Agility SDK loads through `D3D12GetInterface` → `ID3D12SDKConfiguration1::CreateDeviceFactory`,** with no
  exe-export fallback. The `D3D12SDKVersion`/`D3D12SDKPath` exports are removed.
- **Branch `graphics-factory`** in the aggregate, ethereal-nvrhi, ethereal-donut and ethereal-samples. Commit only when
  asked.

Unchanged conventions: COM ABI rules (`ethereal-nvrhi/doc/com-interface-abi.md`), `c_HeaderVersion` stays 28, no
smart-pointer parameters, and the interface headers are shown to the user before any implementation.

## Step 0: branches, Agility probe (gate), reference captures

- Create `graphics-factory` in the four repos.
- **Gate:** build a ~50-line scratchpad probe that runs `LoadLibrary("d3d12.dll")` → `D3D12GetInterface(CLSID_D3D12SDKConfiguration,
  IID_ID3D12SDKConfiguration1)` → `CreateDeviceFactory(<version>, ".\\D3D12\\")` → `ID3D12DeviceFactory::CreateDevice`
  on this machine (Win10 19045).
  - The docs list D3D12GetInterface as Build 20348+, and the pinned SDK 1.619.6 may lack `ID3D12SDKConfiguration1`.
  - Find the minimum SDK version that works, whether the path is exe-relative, and whether
    `GetConfigurationInterface(CLSID_D3D12Debug)` loads D3D12SDKLayers.
  - **If it does not work, stop and report** (no export fallback).
- Reference captures before any change, one GPU run at a time:
  - sample screenshots on `-d3d11/-d3d12/-vk`;
  - Asteroids-nvrhi and MultithreadedRendering fps;
  - nv_asteroids `-nodialog -adapter NVIDIA -screenshot`.
  Store them outside the repo (as with `D:\ps\repo\gvdb-slang-reference`).

## Step 1: interface headers + ADR (stop for user review)

All of it follows the ABI rules: `nvrhi::string/vector`, interfaces for callbacks, the WIDL form for structs, FRESULT
+ `I**` outputs, distinct names instead of overloads, `static_assert` sizes, and single inheritance with a fresh IID
per derived interface.

### `include/nvrhi/factory.h`: common part (pulls in no D3D/Vulkan/CUDA header)

- No `GraphicsFactoryDesc` here; each backend header has its own (below).
- `AdapterInfo` (plain struct): name, vendor/device ID, dedicated memory, uuid[16]/luid[8] + valid flags, discrete
  flag, `NativeObject nativeAdapter` (`IDXGIAdapter1*` / `VkPhysicalDevice`; not AddRef'd, valid while the factory
  lives).
- `NVRHI_IID(IGraphicsFactory)`, `struct IGraphicsFactory : IObject`, the common base:
  - `GraphicsAPI getGraphicsAPI()`
  - `uint32_t getAdapterCount()`, `AdapterInfo& getAdapterInfo(AdapterInfo& retVal, uint32_t index)`
  - `NativeObject getNativeObject(ObjectType)`: DXGI factory, `ID3D12DeviceFactory`, VkInstance,
    `vkGetInstanceProcAddr`
  - `FRESULT createValidationLayer(IDevice* underlying, IDevice** ppDevice)` (stays common)
- `nvrhiCreateGraphicsFactory` is removed. Each backend has its own creation export, which replaces ADR 0010's single
  export (the new ADR records this):
  - `nvrhiD3D11CreateGraphicsFactory(const d3d11::GraphicsFactoryDesc*, d3d11::IGraphicsFactory**)`, and likewise
    `nvrhiD3D12...`, `nvrhiVulkan...`, `nvrhiCudaCreateGraphicsFactory`.
  - Each has an inline wrapper, e.g. `d3d12::createGraphicsFactory(desc)` returning `d3d12::GraphicsFactoryHandle`.
  - Each returns `FE_UNSUPPORTED` if its runtime does not load (DLL, driver, Agility device factory). That replaces
    `isBackendAvailable`.
  - Each export lives in its backend library. An application links only the backends it uses; `nvrhi_factory` goes
    away or becomes an empty interface target.
- The per-backend methods of today's factory (`createD3D11Device`, `createD3D12Device`, `createVulkanDevice`,
  `createCudaDevice`, `isBackendAvailable`) move into the backend factories.

### `include/nvrhi/swapchain.h`: common swap-chain interface

- `SwapChainDesc`:
  - `NativeObject window`: `HWND` on Windows. Non-Windows builds add `NativeObject display` and treat `window` as an
    X11 `Window`; the platform is a compile-time choice, and only Win32 is verified here.
  - width/height, bufferCount, format, sample count/quality, maxFramesInFlight, vsync, refreshRate, dxgiUsage.
- `NVRHI_IID(IGraphicsSwapChain)`, `struct nvrhi::IGraphicsSwapChain : IObject`:
  - `getDesc()`: the actual format and size (e.g. Vulkan's SRGBA8→SBGRA8 swap).
  - `getBackBufferCount()`, `getBackBuffer(i)` (no AddRef), `getCurrentBackBufferIndex()`.
  - `beginFrame()`: the backend's frame-start wait (see below).
  - `present()`: signal + present + frame pacing.
  - `resize(w, h)`: 0 means the current surface extent. The caller drops its framebuffer references first.
  - `setVsyncEnabled`, `getNativeSwapChain`.
- New error code `FE_OUT_OF_DATE = -10` (appended), returned by `beginFrame`/`present` when a resize is needed.

### Backend headers: factory, creation desc, swap chain per backend

Each backend header (`d3d11.h`, `d3d12.h`, `vulkan.h`, `cuda.h`) adds:

- `<backend>::GraphicsFactoryDesc`, with only the settings that backend reads:
  - D3D11: `messageCallback`, `enableDebugRuntime` (DXGI debug factory + D3D11 debug flag), `dxgiLibraryName`,
    `d3d11LibraryName`.
  - D3D12:
    - `messageCallback`;
    - `enableDebugRuntime` (DXGI debug factory + D3D12 debug layer), `enableGPUValidation`, `enableWarningsAsErrors`;
    - `d3d12SDKVersion` (0 = system D3D12) and `d3d12SDKPath` for the Agility device factory;
    - `dxgiLibraryName`, `d3d12LibraryName` (Streamline: `sl.interposer.dll`).
  - Vulkan:
    - `messageCallback`;
    - `enableDebugRuntime` (`VK_LAYER_KHRONOS_validation` + debug report), `enableRayTracingValidation` (sets
      `NV_ALLOW_RAYTRACING_VALIDATION` before the ICD loads, adds debug-utils);
    - `headless` (no surface extensions);
    - `vulkanLibraryName`, required/optional instance extensions and layers;
    - `ignoredVulkanValidationMessageLocations`.
  - CUDA: `messageCallback`, `driverLibraryName`. This moves from `cuda::DeviceDesc`, because the factory loads the
    driver.
- `<backend>::DeviceCreationDesc`. It has no native-object fields; the non-native settings are repeated from
  `DeviceDesc` (ABI §4.1: no base class):
  - D3D11: `messageCallback`, `adapterIndex = -1`, `featureLevel`, `aftermathEnabled`.
  - D3D12: `errorCB`, `adapterIndex = -1`, `featureLevel`, `enableComputeQueue`, `enableCopyQueue`, the four heap
    sizes, `maxTimerQueries`, `enableHeapDirectlyIndexed`, `aftermathEnabled`, `logBufferLifetime`,
    `enableRayTracingValidation`, `enableEnhancedBarriers`.
  - Vulkan:
    - `errorCB`, `adapterIndex = -1`, required/optional device extensions;
    - `enableComputeQueue`, `enableCopyQueue`, `enableRayTracingExtensions`, `enableHeapDirectlyIndexed`,
      `enableCbvDescriptorStreaming`;
    - multiview requirements, `physicalDeviceFeatures2Extensions` (`void*`);
    - `IDeviceCreateCallback*`: `onCreateDevice(VkDeviceCreateInfo&)`, replaces `std::function`;
    - optional present compatibility (window handle, format, buffer count, extent), checked against a temporary
      surface as `pickPhysicalDevice` does today;
    - `maxTimerQueries`, `aftermathEnabled`, `logBufferLifetime`.
  - CUDA: no `DeviceCreationDesc`. `cuda::DeviceDesc` already holds no native objects (ordinal or `graphicsDevice`),
    and `createDevice` takes it.
- `<backend>::IGraphicsFactory : nvrhi::IGraphicsFactory`, each with a fresh IID:
  - `FRESULT createDevice(const DeviceDesc& desc, <backend>::IDevice** ppDevice)`: today's
    `IGraphicsFactory::create<Backend>Device`, moved into the backend factory and renamed. It is the unchanged wrap
    path for caller-made native devices; WaveWorks and the WARP-based nvrhi tests use it. For CUDA it is today's
    `createCudaDevice(const cuda::DeviceDesc&)`.
  - `FRESULT createDeviceOnAdapter(const DeviceCreationDesc& desc, <backend>::IDevice** ppDevice)` (D3D11, D3D12,
    Vulkan). It cannot also be called `createDevice`: ABI R3 forbids overloads.
    - It selects the adapter and creates every native object inside.
    - D3D11: `ID3D11Device` + immediate context.
    - D3D12: `ID3D12Device` through the Agility device factory, plus the graphics/compute/copy queues.
    - Vulkan: picks the physical device on the factory's VkInstance, creates the VkDevice, and gets the
      graphics/compute/transfer/present queues.
    - Then it builds the existing `DeviceDesc` internally and calls the same backend path as `createDevice`.
  - D3D11 returns `nvrhi::IDevice**` from both, as today.
  - `FRESULT createSwapChain(const SwapChainDesc& desc, <backend>::IDevice* device, <backend>::IGraphicsSwapChain**)`.
    The device may also be the validation-layer wrapper; the factory unwraps it inside the module.
  - Backend extras:
    - D3D factories: `reportLiveObjects()`.
    - Vulkan factory: `getEnabledInstanceExtensions(names, capacity)`, `getEnabledLayers(names, capacity)`.
  - Method names are open to change in the header review.
- `<backend>::IGraphicsSwapChain : nvrhi::IGraphicsSwapChain`, each with a fresh IID, plus backend accessors:
  - D3D11: the `IDXGISwapChain*`. `beginFrame` does nothing.
  - D3D12: `IDXGISwapChain3*` and the frame fence. `beginFrame` waits on the CPU for the current frame fence's sync
    point (the `ID3D12Fence` value signalled when this back buffer was last presented).
  - Vulkan: `VkSwapchainKHR`, `VkSurfaceKHR`. `beginFrame` acquires the next image and queues the semaphore wait on
    the graphics queue.
  - CUDA: windowless. `window` is null; my reading, to be confirmed in the header review.
    - The back buffers are CUDA textures.
    - `present()` records the stream's last executed command-list instance for the slot (or a CUDA event) and rotates
      to the next slot.
    - `beginFrame()` waits for that slot's in-flight stream work.
    - Displaying the image through `IInteropDevice` is out of scope.
- `vulkan::IDevice` gains `getEnabledDeviceExtensions(names, capacity)`, which WaveWorks needs.

### Docs

- `doc/adr/0014-per-backend-graphics-factories-and-swap-chains.md`: supersedes 0010's single export and method list
  with per-backend factories, factory descriptors and exports. Add an index row, and mark 0010 "Superseded by 0014".
- Maintained plan `doc/plans/2026-10-26-graphics-factory-swap-chain.md`. The aggregate `docs/plans` gets an
  as-approved copy with a pointer line.
- **Show the headers and the ADR to the user, and wait for their feedback before Step 2.**

## Step 2: nvrhi implementation

Port donut's code; don't rewrite its behaviour.

- **Layout:**
  - Each backend factory and swap chain lives in its backend library: `src/d3d11/d3d11-factory.cpp`,
    `d3d11-swapchain.cpp`, `src/d3d12/...`, `src/vulkan/vulkan-factory.cpp`, `vulkan-swapchain.cpp`,
    `src/cuda/cuda-factory.cpp`, `cuda-swapchain.cpp`.
  - Their module-private constructors are declared in `src/common/backend-factories.h`.
  - The shared DXGI code (factory, adapter enumeration, `LoadLibrary` of dxgi) goes in a private `src/common/dxgi-*.cpp`,
    which both D3D libraries compile.
  - Each backend library defines its own `nvrhi<Backend>CreateGraphicsFactory` export. `src/factory/factory.cpp` is
    deleted; the validation-layer creation it held moves to a helper shared by the backend factories.
  - In CMake, the `nvrhi_factory` target becomes an empty compatibility interface target, or is removed with its
    users updated.
- **D3D loading:**
  - `LoadLibrary` for dxgi/d3d11/d3d12 (name overrides honoured).
  - Resolve `CreateDXGIFactory2`, `DXGIGetDebugInterface1`, `D3D11CreateDevice`, `D3D12GetInterface`.
  - The D3D12 factory creates an `ID3D12DeviceFactory` when `d3d12SDKVersion != 0`, and uses it for devices and for
    the debug/GBV configuration.
- **D3D devices:**
  - Port the adapter selection and enumeration, D3D11/D3D12 device creation, the InfoQueue deny list and break-on
    settings, and queue creation from `DeviceManager_DX12.cpp:152-310` and `DeviceManager_DX11.cpp:150-237`.
- **Vulkan:**
  - Port the instance (created lazily when the factory is created), the debug report/utils callbacks, enumeration,
    `pickPhysicalDevice`, `findQueueFamilies` and `createDevice` with its feature chains, from
    `DeviceManager_VK.cpp:101-945, 1071-1164`.
  - The platform surface extension replaces `glfwGetRequiredInstanceExtensions`. A surface or platform presentation
    query replaces `glfwGetPhysicalDevicePresentationSupport`.
  - Messages go to the factory's `IMessageCallback`.
- **`createDeviceOnAdapter` flow:** select the adapter and create the native device and queues, build a local
  `DeviceDesc`, then call the backend `CreateDevice` (the same one `createDevice` uses). On failure, release whatever
  was already created.
- **Ownership:**
  - Native devices that `createDeviceOnAdapter` creates are owned by the nvrhi device. A private flag passed to the backend
    `CreateDevice` makes the Vulkan device call `vkDestroyDevice`; the D3D devices hold COM references.
  - Every device and swap chain holds a reference to its factory, so the VkInstance, DXGI factory and loaded DLLs
    outlive them.
  - The Vulkan device records the present queue and its family.
- **Dispatcher:**
  - `VULKAN_HPP_DEFAULT_DISPATCH_LOADER_DYNAMIC_STORAGE` becomes unconditional in `src/vulkan/vulkan-device.cpp`. The
    Vulkan factory initializes it: loader, then instance, then device.
  - The wrap path keeps today's behaviour.
  - Remove the duplicate storage definitions:
    - donut `DeviceManager_VK.cpp:66`
    - donut `tests/src/vulkan_dispatch_storage.cpp`, if nothing else needs it
    - nvrhi tests `qi-device.cpp:34`, `memory-queries.cpp:29`, `cuda-tests.cpp:51`
    - WaveWorks `sdk/src/VulkanDispatch.cpp:5`. This SHARED lib links `nvrhi_vk` statically and keeps its init
      function.
- **Swap chains:**
  - D3D12 from `DeviceManager_DX12.cpp:344-594`. `beginFrame` is `BeginFrame` (`WaitForSingleObject` on the current
    back buffer's frame-fence event).
  - D3D11 from `DeviceManager_DX11.cpp:268-433`.
  - Vulkan from `DeviceManager_VK.cpp:959-1067, 1266-1445`. `beginFrame` = `acquireNextImageKHR` +
    `queueWaitForSemaphore`. Also ported: present semaphores, event-query frames in flight, out-of-date →
    `FE_OUT_OF_DATE`.
  - CUDA: new code. Per-slot instance or CUDA event; `beginFrame` waits on it, `present` records it and rotates.
- **Implicit linking:**
  - `nvrhi_d3d11`/`nvrhi_d3d12` stop linking `d3d11`/`d3d12` (keep `dxguid`).
  - `d3d12-resource-bindings.cpp:764` uses `ID3D12DeviceConfiguration::SerializeVersionedRootSignature` when available,
    and otherwise the loaded or `GetModuleHandle` `D3D12SerializeVersionedRootSignature`.
- **Callers of the old factory methods move to the backend factories:**
  - nvrhi tests `test-factory.h`, `qi-device.cpp`, `cuda-tests.cpp`, `memory-queries.cpp`
  - the WaveWorks SDK
  - GVDB samples using `createCudaDevice`
  - donut
- **Tests:**
  - `memory-queries`/`qi-device`: switch their Agility SDK D3D12 path to
    `d3d12::IGraphicsFactory::createDeviceOnAdapter`. Their WARP/native paths use the backend factory's `createDevice`.
  - New factory test, per backend:
    - create the factory, enumerate adapters, and `createDeviceOnAdapter` headless;
    - create a swap chain on a hidden Win32 window and exercise `beginFrame`/`present`/`resize`;
    - CUDA: a windowless swap chain whose `beginFrame` blocks until the slot's stream work has completed.

## Step 3: donut DeviceManager becomes a factory client

- `DeviceManager.h`: `InstanceParameters`/`DeviceCreationParameters` and donut's `AdapterInfo` stay source-compatible.
  Add `d3d12AgilitySDKVersion`/`d3d12AgilitySDKPath`.
  - `CreateInstance` → `CreateInstanceInternal` (per backend) builds that backend's `<backend>::GraphicsFactoryDesc`
    from `InstanceParameters` and creates the backend factory. Each subclass keeps its typed handle; the base keeps it
    as `nvrhi::IGraphicsFactory`.
  - `GetGraphicsFactory()` returns it as `nvrhi::IGraphicsFactory*`. An app that wants a paired CUDA device now
    creates a `cuda::IGraphicsFactory`; GVDB samples are updated.
  - `EnumerateAdapters` fills donut's `AdapterInfo` from `getAdapterInfo`. `dxgiAdapter` is AddRef'd from
    `nativeAdapter`.
  - The `IsVulkan*Enabled`/`GetEnabledVulkan*` queries go to the Vulkan factory and device.
  - A small ObjectImpl adapts `deviceCreateInfoCallback` to `vulkan::IDeviceCreateCallback`.
- The base class owns `nvrhi::AutoPtr<nvrhi::IGraphicsSwapChain> m_SwapChain` and implements:
  - BeginFrame: `beginFrame()`. On `FE_OUT_OF_DATE` it runs BackBufferResizing → `resize(0,0)` → read the size back →
    BackBufferResized, at most 3 tries, as today.
  - Present, ResizeSwapChain, `GetBackBuffer*`, `GetCurrentBackBufferIndex`, `GetBackBufferCount`.
  - The window handle comes from `glfwGetWin32Window` (`glfwGetX11Window`/`glfwGetX11Display` elsewhere).
- `DeviceManager_DX11/DX12/VK`:
  - `CreateDevice` fills `<backend>::DeviceCreationDesc` and calls the backend factory's `createDeviceOnAdapter`.
  - `CreateSwapChain` calls the backend factory's `createSwapChain`.
  - Donut holds no native device, queue, instance or physical device. Where it needs one (Streamline,
    `MoveWindowOntoAdapter`, WaveWorks), it reads it through `getNativeObject`/`getNativeQueue`.
  - They keep `GetRendererString`/`m_IsNvidia` (adapter matched by LUID) and the Streamline hooks.
  - `ReportLiveObjects` calls the D3D factory's `reportLiveObjects()`.
- Streamline:
  - The interposer goes through the factory's library-name overrides instead of the link order in
    `donut-app.cmake:38-46`.
  - `FindBestAdapterDX` feeds `adapterIndex`. `FindBestAdapterVulkan` is applied to the enumerated adapter list.
  - No sample enables Streamline: it is compile-checked only if it can be configured, otherwise recorded as
    unverified.
- `donut-app.cmake`: drop `d3d11`/`d3d12`/`dxgi` from donut_app's link line where nothing else in donut needs them.
- Agility SDK:
  - donut_app deploys D3D12Core/SDKLayers (`cmake/FetchAgilitySDK.cmake`) and passes the version from a compile
    definition by default.
  - Remove the exports in `tests/src/engine/test_float.cpp:27-28`; that test gets the preview version through the
    parameters.

## Step 4: samples

- `ethereal-samples/src/CMakeLists.txt`:
  - `ethereal_use_agility_sdk()` drops `AgilitySDKExports.cpp` and only deploys the DLLs and sets the version
    definition, or defers to donut.
  - Delete `AgilitySDKExports.cpp`.
  - Replace the `work_graphs_d3d12.cpp:942-943` exports with DeviceManager parameters.
- Callers of donut's AdapterInfo, extension queries and `deviceCreateInfoCallback` should compile unchanged; fix any
  that do not:
  - `headless.cpp`
  - WaveWorks `example_app.cpp:163-165, 316-341`
  - `nv_asteroids main.cpp:370-380`
  - the Asteroids/MTR nvrhi `main.cpp`
  - VXGI/DDGI/GVDBApp
- GVDB samples that create a CUDA device through `GetGraphicsFactory()->createCudaDevice` switch to a
  `cuda::IGraphicsFactory`.

## Verification

1. **Build:** full configure per the build-everything recipe (VsDevCmd shell, `x64-windows-static`, all
   ETHEREAL/NVRHI test flags), `cmake --build build --config Release -- -k 0`, then Debug. Then `ctest -C Release`,
   including `nvrhi_abi_lint`, `nvrhi_header_hygiene`, `nvrhi_header_tus`, the new factory test, qi-device,
   memory-queries and cuda-tests.
2. **Implicit loading:**
   - `dumpbin /dependents` on a donut sample and on the nvrhi tests lists no `d3d11/d3d12/dxgi.dll` and no
     `vulkan-1.dll`.
   - `dumpbin /exports` shows no `D3D12SDKVersion`.
   - At run time, D3D12Core.dll is loaded from `bin\D3D12` (module list).
3. **Samples, with `--debug` and validation,** one GPU process at a time, with debug output captured by PID via DBWIN:
   - basic sample on `-d3d11/-d3d12/-vk`
   - RT samples (rt_triangle, rt_shadows, ddgi with `cornell.cfg.json`)
   - work_graphs
   - VXGI, GVDB (CUDA factory), headless, WaveWorks, nv_asteroids

   Screenshots must match the Step 0 references, and there must be no new D3D debug-layer or VVL messages.
4. **Swap-chain behaviour per API:** resize, maximize, minimize/restore, Alt+Enter, vsync toggle, close, and
   Vulkan out-of-date.
5. **Performance:** Asteroids-nvrhi and MultithreadedRendering fps within noise of Step 0, using the thermal
   protocol.
6. **Optional shared build:** `-DNVRHI_BUILD_SHARED=ON` configure + build; `dumpbin /exports nvrhi.dll` lists only
   `nvrhi*` names.

Write each step's "as built" notes into the maintained plan in `ethereal-nvrhi/doc/plans`, and update memory: the
branch exception and project status.

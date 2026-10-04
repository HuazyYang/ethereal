# Naming Style

## 1. Files and directories

### 1.1 Directories

Directory names **must** be `snake_case`: lowercase words separated by underscores. This applies to
the `ethereal` aggregate, `donut` and `nvrhi`.

- Good: `shader_tools`, `render_passes`, `framegraph`
- Bad: `shaderTools`, `Render_Passes`, `RenderPasses`, `render-passes`

A single compound word that is conventionally written without a break needs no underscore:
`framebuffer`, `framegraph`, `thirdparty`.

The rule applies to **new** directories. The following predate it and are deliberately left
unchanged; do not treat them as precedent:

| Directory | Why it stays |
| --- | --- |
| `donut/thirdparty/shader-tool` | A submodule path and the upstream repository name (`HuazyYang/shader-tool`). Renaming it would churn `.gitmodules` and the CMake paths that reference it. |
| `donut/thirdparty/jsoncpp-amalgam` | Third-party source drop; keeps its upstream spelling. |
| `ethereal-samples` | A submodule path and the repository name, referenced from the aggregate's `.gitmodules`. |

See [`../adr/0001-snake-case-directory-names.md`](../adr/0001-snake-case-directory-names.md).

### 1.2 Files

File names **may** use one of the following styles:

| Style        | Example             |
| ------------ | ------------------- |
| `kebab-case` | `render-pass.cpp`   |
| `snake_case` | `render_pass.cpp`   |
| `PascalCase` | `RenderPass.cpp`    |

File names **must never** use `camelCase` (e.g. `renderPass.cpp`).

Pick one style per directory and keep it consistent within that directory. Note that this is a
separate question from directory naming: an `adr/` directory whose files are `kebab-case`
(`0001-snake-case-directory-names.md`) is correct, because the directory name itself is `snake_case`
and the files follow one consistent style.

## 2. Macros

Macro names **must** be `UPPER_SNAKE_CASE`: uppercase words separated by underscores.

- Good: `MAX_FRAME_COUNT`, `ETHEREAL_ASSERT`
- Bad: `maxFrameCount`, `Max_Frame_Count`, `EtherealAssert`

This applies to object-like macros, function-like macros and include guards.

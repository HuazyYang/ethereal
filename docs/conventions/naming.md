# Naming Style

## 1. Files and directories

### 1.1 Directories

Directory names **must** be `kebab-case`: lowercase words separated by hyphens.

- Good: `shader-tools`, `render-passes`
- Bad: `shaderTools`, `Render_Passes`, `RenderPasses`

### 1.2 Files

File names **may** use one of the following styles:

| Style        | Example             |
| ------------ | ------------------- |
| `kebab-case` | `render-pass.cpp`   |
| `snake_case` | `render_pass.cpp`   |
| `PascalCase` | `RenderPass.cpp`    |

File names **must never** use `camelCase` (e.g. `renderPass.cpp`).

Pick one style per directory and keep it consistent within that directory.

## 2. Macros

Macro names **must** be `UPPER_SNAKE_CASE`: uppercase words separated by underscores.

- Good: `MAX_FRAME_COUNT`, `ETHEREAL_ASSERT`
- Bad: `maxFrameCount`, `Max_Frame_Count`, `EtherealAssert`

This applies to object-like macros, function-like macros and include guards.

# Vulkan Engine - Project Architecture & Structure

## 1. Build System

**Build System:** Zig Build System
- **Language:** Zig (systems programming language)
- **Minimum Version:** 0.16.0
- **Files:**
  - `build.zig` - Main build configuration
  - `build.zig.zon` - Zig dependency manifest (currently has no external dependencies)

### Build Features
- **Shader Compilation:** Automatic GLSL to SPIR-V compilation using `glslc`
  - Shaders are discovered by walking `shaders/` via `std.Io.Dir` (Zig 0.16 std.Io API)
  - Compiled outputs are added as anonymous module imports and embedded via `@embedFile` in `main.zig`
  - Located in `compileAllShaders()` function
- **System Library Linking:**
  - `glfw3` - Window and input management
  - `vulkan` - Vulkan API
  - `gl` - On Linux only
- **Test Infrastructure:** Built-in test support via `zig build test`

### Development Setup
Two options for local development:

**Option 1 - Nix (Recommended):**
```bash
nix develop
nix develop --command zig build run
```

**Option 2 - Manual Setup:**
Install required dependencies:
- Zig 0.15.2+
- GLFW3
- Vulkan SDK
- shaderc/glslc (for shader compilation)

### Build Commands
```bash
zig build              # Build executable
zig build run          # Build and run
zig build test         # Run tests
```

---

## 2. Project Directory Structure

```
vulkan-engine/
├── build.zig              # Build configuration (Zig build system)
├── build.zig.zon          # Zig manifest/dependencies
├── flake.nix              # Nix development environment
├── flake.lock             # Pinned Nix inputs
├── README.md              # Basic project info
├── AGENTS.md              # This file (project guidance for agents)
├── codebook.toml          # Codebook configuration
├── .agents/
│   └── skills/            # Agent skills (e.g. zig 0.16 porting notes)
├── .github/
│   └── workflows/
│       └── ci.yaml        # GitHub Actions CI/CD
├── src/                   # Core application source
│   ├── main.zig           # Entry point
│   ├── Vulkan.zig         # Vulkan instance & initialization
│   ├── Device.zig         # Physical/logical device management
│   ├── Window.zig         # GLFW window management
│   ├── Pipeline.zig       # Graphics pipeline configuration
│   ├── Loop.zig           # Main event loop
│   ├── c.zig              # C interop definitions
│   └── utils.zig          # Utility functions
├── shaders/               # GLSL shader source files
│   ├── shader.vert        # Vertex shader
│   └── shader.frag        # Fragment shader
└── zig-out/               # Build output directory (generated)
```

---

## 3. Core Architectural Components

### 3.1 Component Overview

The engine follows a layered architecture with clear separation of concerns:

```
main.zig (Entry Point)
    ↓
Loop.zig (Event Loop) ←→ Window.zig (GLFW Window)
                              ↓
Device.zig (Vulkan Device) ← Device Selection & Creation
    ↓
Vulkan.zig (Instance & Core)
    ↓
Pipeline.zig (Graphics Pipeline)
    ↓
c.zig (C FFI Layer)
    ↓
External Libraries (GLFW, Vulkan)
```

### 3.2 Component Descriptions

#### **main.zig** - Entry Point
- **Purpose:** Application initialization and lifecycle management
- **Window Size:** 800x600
- **Key Functions:**
  - `main()` - Initialize and run the application
- **Initialization Order:**
  1. Create window
  2. Initialize device
  3. Create event loop
  4. Initialize graphics pipeline
  5. Start event loop

#### **Window.zig** - GLFW Window Management
- **Purpose:** Handle window creation and surface management
- **Type:** Struct with `instance`, `width`, `height` fields
- **Key Functions:**
  - `init(width, height)` - Create GLFW window
  - `deinit()` - Clean up window resources
  - `should_close()` - Check if window close requested
  - `create_surface(instance, surface)` - Create Vulkan surface for rendering
- **Configuration:**
  - No API client (using Vulkan)
  - Non-resizable window
  - Uses GLFW C library bindings

#### **Vulkan.zig** - Vulkan Instance & Core Setup
- **Purpose:** Vulkan instance creation, validation layers, and device querying
- **Type:** Struct with `instance` field
- **Key Functions:**
  - `init(alloc, enable_validation_layers)` - Create Vulkan instance
  - `deinit()` - Destroy instance
  - `createLogicalDevice()` - Create logical device from physical device
  - `findQueueFamilies()` - Find graphics and present queue families
  - `checkDeviceExtensionSupport()` - Verify required extensions
  - `querySwapChainSupport()` - Check swapchain capabilities
- **Validation Layers:**
  - `VK_LAYER_KHRONOS_validation` - Used in debug builds
- **Extensions Handled:**
  - Platform-specific extensions (macOS portability)
  - Debug utilities
  - Swapchain extensions
- **Features:**
  - Automatic validation layer detection
  - Debug callback for validation messages
  - Cross-platform extension handling (macOS-specific workarounds)

#### **Device.zig** - Physical & Logical Device Management
- **Purpose:** GPU selection and device creation
- **Type:** Struct with device references, queues, and command pool
- **Fields:**
  - `window` - Reference to window
  - `enable_validation_layers` - Debug mode flag
  - `surface` - Vulkan surface
  - `vulkanInstance` - Vulkan instance
  - `physicalDevice` - Selected GPU
  - `globalDevice` - Logical device
  - `graphicsQueue` - Graphics command queue
  - `presentQueue` - Presentation queue
  - `commandPool` - Command buffer pool
- **Key Functions:**
  - `init(alloc, window)` - Initialize device and queues
  - `deinit()` - Clean up device resources
  - `pickPhysicalDevice()` - Select suitable GPU
  - `isDeviceSuitable()` - Check device capabilities
  - `createCommandPool()` - Create command buffer pool
  - `createShaderModule()` - Compile shader bytecode into module
- **Device Selection Criteria:**
  - Queue family support (graphics and present)
  - Required extension support
  - Swapchain format availability

#### **Pipeline.zig** - Graphics Pipeline Configuration
- **Purpose:** Graphics pipeline creation and configuration
- **Type:** Struct with pipeline handle, shader modules, layout, and render pass
- **Fields:**
  - `device` - Reference to device
  - `graphicsPipeline` - Optional `VkPipeline` handle
  - `vertShaderModule` - Vertex shader module
  - `fragShaderModule` - Fragment shader module
  - `pipelineLayout` - `VkPipelineLayout` handle
  - `renderPass` - `VkRenderPass` handle
- **Key Structures:**
  - `PipelineConfigInfo` - Complete pipeline configuration state
- **Key Functions:**
  - `init(device, fragShader, vertShader, configInfo)` - Create pipeline layout, render pass, shader modules and graphics pipeline
  - `defaultPipelineConfigInfo(width, height)` - Generate default pipeline config
  - `createPipelineLayout(device)` - Create empty pipeline layout (no descriptors / push constants)
  - `createRenderPass(device)` - Create a single-subpass render pass with a `B8G8R8A8_UNORM` color attachment for swapchain presentation
- **Pipeline Configuration (defaultPipelineConfigInfo):**
  - Viewport and scissor setup
  - Input assembly (triangle list topology)
  - Rasterization (fill mode, no culling)
  - Multisampling (1x MSAA)
  - Color blending (no blending)
  - Depth/Stencil testing (depth test enabled, less comparison)
- **Shader Stages:**
  - Vertex: Generates triangle in NDC space
  - Fragment: Outputs red color

#### **Loop.zig** - Main Event Loop
- **Purpose:** Application event processing
- **Type:** Struct with window reference
- **Key Functions:**
  - `init(window)` - Initialize event loop
  - `deinit()` - Clean up
  - `is_running()` - Check if should continue
- **Current Implementation:**
  - Delegates to window's `should_close()` check
  - Uses GLFW event polling in main loop

#### **c.zig** - C FFI Layer
- **Purpose:** C interoperability bindings
- **Content:**
  - Defines `GLFW_INCLUDE_VULKAN` for GLFW/Vulkan integration
  - Imports `GLFW/glfw3.h` - Window system
  - Imports `vulkan/vulkan_beta.h` - Vulkan API
- **Usage:** All C API calls go through `c.c` namespace

#### **utils.zig** - Utility Functions
- **Purpose:** Common utility functions
- **Key Functions:**
  - `checkSuccess(result)` - Validate Vulkan result codes
  - Converts Vulkan errors to Zig error types

### 3.3 Data Flow

**Initialization Flow:**
```
main.zig
  ├─→ Window.init()
  │    └─→ glfwInit() + glfwCreateWindow()
  │
  ├─→ Device.init()
  │    ├─→ Vulkan.init()
  │    │    └─→ vkCreateInstance()
  │    │
  │    ├─→ Window.create_surface()
  │    │    └─→ glfwCreateWindowSurface()
  │    │
  │    ├─→ Device.pickPhysicalDevice()
  │    │    └─→ vkEnumeratePhysicalDevices()
  │    │
  │    └─→ Vulkan.createLogicalDevice()
  │         └─→ vkCreateDevice()
  │
  ├─→ Loop.init()
  │
  └─→ Pipeline.init()
       ├─→ Create shader modules
       └─→ vkCreateGraphicsPipelines()
```

**Runtime Flow:**
```
while Loop.is_running():
  glfwPollEvents()  // Handle window events
  // TODO: Render pass execution
```

---

## 4. Vulkan Rendering Pipeline Organization

### 4.1 Pipeline Architecture

The rendering pipeline is structured in stages following the Vulkan graphics pipeline model:

**1. Instance & Device Setup**
- Location: `Vulkan.zig` + `Device.zig`
- Creates Vulkan instance with platform-specific extensions
- Selects suitable physical device
- Creates logical device with graphics and presentation queues

**2. Surface & Swapchain (Partial)**
- Location: `Window.zig` + `Vulkan.zig`
- Creates presentation surface via GLFW
- Swapchain capabilities are queried but not fully implemented

**3. Shader Compilation**
- Location: `build.zig` + `shaders/`
- Build-time: GLSL shaders compiled to SPIR-V
- Runtime: Shader binaries embedded and loaded into modules
- Files:
  - `shader.vert` - Vertex shader
  - `shader.frag` - Fragment shader

**4. Graphics Pipeline**
- Location: `Pipeline.zig`
- Configures entire graphics pipeline state
- Combines shader stages with rasterization configuration
- Default configuration includes:
  - Triangle list topology
  - Fill polygon mode
  - Depth testing with less comparison
  - No color blending

**5. Rendering (TODO)**
- Command buffer recording
- Render pass execution
- Frame submission

### 4.2 Shader Details

**Vertex Shader (`shader.vert`):**
```glsl
#version 450
// Hardcoded triangle in NDC space
vec2 positions[3] = vec2[](
    vec2(0.0, -0.5),   // Bottom
    vec2(0.5, 0.5),    // Right
    vec2(-0.5, 0.5)    // Left
);

void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
```

**Fragment Shader (`shader.frag`):**
```glsl
#version 450
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(1.0, 0.0, 0.0, 1.0);  // Red
}
```

**Current State:** Renders a static red triangle (proof of concept)

### 4.3 Key Configuration Parameters

**Viewport & Scissor:**
- Viewport size: 800x600
- Depth range: 0.0 to 1.0

**Rasterization:**
- Polygon mode: Fill
- Cull mode: None
- Front face: Clockwise
- Line width: 1.0

**Color Blending:**
- Disabled (no blending operations)
- RGBA write mask: All channels enabled

**Depth Stencil:**
- Depth test: Enabled
- Depth write: Enabled
- Depth compare op: Less
- Stencil test: Disabled

---

## 5. Configuration Files

### 5.1 Build Configuration

**build.zig**
- Zig build system configuration
- Handles shader compilation
- Links system libraries (GLFW, Vulkan)
- Defines build steps (run, test)
- Target and optimization settings

**build.zig.zon**
- Package metadata
- Project name: `vulkan_engine`
- Version: 0.0.0
- Minimum Zig version: 0.16.0
- Dependencies: None (using system libraries)

### 5.2 Development Environment

**flake.nix**
- Nix package manager configuration
- Provides reproducible development environment
- Dependencies:
  - `zig` - Compiler
  - `zls` - Language server
  - `shaderc` - Shader compilation
  - `vulkan-headers`, `vulkan-loader`, `vulkan-validation-layers`
  - `glfw` - Window system
  - `pkg-config` - Dependency discovery
  - Platform-specific: `libGL` on Linux

### 5.3 CI/CD Configuration

**.github/workflows/ci.yaml**
- GitHub Actions workflow
- Triggers on PR and push to main
- Runs on Ubuntu Linux
- Steps:
  1. Checkout repository
  2. Install Nix
  3. Run `nix flake check`
  4. Execute: `nix develop -c zig build test --summary all`
- Concurrency control to cancel outdated runs

### 5.4 Git Configuration

**.gitignore**
- Ignores: `zig-out/`, `.zig-cache/`, `*.cpp`, `*.hpp`
- Allows: source code, build files, configuration

---

## 6. Test Setup

### 6.1 Test Infrastructure

**Testing Framework:**
- Built into Zig language
- Uses `@import("builtin")` for compile-time checks
- Test declarations with `test` keyword

**Current Test Setup:**
- Located in: Individual source files
- Test execution: `zig build test`
- CI integration: GitHub Actions runs tests on every PR/push

**Running Tests:**
```bash
zig build test                           # Local testing
zig build test --summary all            # Detailed summary
nix develop -c zig build test           # In Nix environment
```

### 6.2 Test Infrastructure in CI

- Runs on Ubuntu Linux
- Uses Nix for reproducible environment
- Executes full build and test suite
- Generates test summary

### 6.3 Notable Test Features

- No external test framework required (Zig built-in)
- Tests run at compile time when possible
- Can be run in debug and release modes

---

## 7. Key Architectural Patterns

### 7.1 Design Patterns Used

**1. Resource Acquisition Is Initialization (RAII)**
- Each component has `init()` and `deinit()` functions
- Deferred cleanup using `defer` keyword
- Automatic resource management

**2. Struct-Based Components**
- Core components are Zig structs (implicit types via `@This()`)
- Self-contained with encapsulated state
- Methods return modified copies or mutate in-place

**3. C Interoperability Layer**
- Abstraction via `c.zig` module
- Centralized C binding management
- Error handling via `checkSuccess()` wrapper

**4. Configuration Objects**
- `PipelineConfigInfo` - Encapsulates pipeline state
- Allows flexible configuration through builder pattern
- `defaultPipelineConfigInfo()` provides sensible defaults

**5. Allocator Pattern**
- Explicit memory allocation via `std.mem.Allocator`
- Page allocator used in main
- Deferred cleanup for temporary allocations

### 7.2 Error Handling

**Error Management:**
- Zig error union types (`!Type`)
- Try operator (`try`) for error propagation
- `checkSuccess()` converts Vulkan error codes to Zig errors
- Validation layer support for runtime errors

**Example Error Handling:**
```zig
try checkSuccess(c.vkCreateDevice(...))  // Propagates errors
_ = c.vkEnumeratePhysicalDevices(...)    // Ignores result
```

### 7.3 Memory Management

**Allocation Strategy:**
- Page allocator for main application lifetime
- ArrayList for dynamic collections
- Explicit deallocation with `defer`
- No garbage collection (manual management)

**Example:**
```zig
var extensions: std.ArrayList(...) = .empty;
defer extensions.deinit(alloc);
```

---

## 8. Development Notes

### 8.1 Platform-Specific Considerations

**macOS Support:**
- Handles VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
- Requires VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME
- Portability subset extension required

**Linux Support:**
- Includes GL library linking
- Tested in CI pipeline

### 8.2 Known Limitations & TODOs

- Swapchain not fully implemented (capabilities queried only)
- Render pass created, but not yet wired into a draw loop
- Command buffer recording / submission incomplete
- No framebuffer creation, no synchronization primitives
- Validation layer cleanup incomplete — debug messenger destruction is TODO (see `Device.deinit`)
- Single hardcoded triangle (no vertex buffer)
- No transform matrices or camera

### 8.3 Extension References

- Based on Vulkan Tutorial (vulkan-tutorial.com)
- Inspired by Little Vulkan Engine by Brendan Galea
- Related projects: rift-engine

---

## 9. Quick Start for Development

### Setup (with Nix)
```bash
cd /Users/thekorn/devel/github.com/thekorn/vulkan-engine
nix develop
zig build run
```

### Build Targets
```bash
zig build              # Compile executable
zig build run          # Compile and run
zig build test         # Run test suite
zig build --help       # Show all options
```

### Key File Locations
- Entry point: `/src/main.zig`
- Shader sources: `/shaders/`
- Build config: `/build.zig`
- Dev environment: `/flake.nix`

### IDE Support
- ZLS (Zig Language Server) included in Nix env
- Requires editor with LSP support

---

## 10. Architecture Summary

**Architecture Type:** Layered, Component-Based

**Tier Structure:**
1. **Application Layer** (main.zig, Loop.zig)
2. **High-Level Abstractions** (Window, Device, Pipeline)
3. **Vulkan Core Layer** (Vulkan.zig)
4. **FFI/Interop Layer** (c.zig, utils.zig)
5. **Native Libraries** (GLFW, Vulkan SDK)

**Key Strengths:**
- Clear separation of concerns
- Modular component design
- Proper resource cleanup
- Type-safe Vulkan bindings
- Cross-platform support

**Current Stage:** Foundation/Infrastructure complete, rendering pipeline work-in-progress


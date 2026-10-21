# NVN → Metal object mapping

中文：[nvn_metal_mapping.zh-CN.md](nvn_metal_mapping.zh-CN.md)

This document lists what each kind of NVN (the Switch's native graphics interface) object and command lands on in Metal within D2R Mobile's graphics layer. For the overall structure of the graphics layer see [README.md](README.md).

Scope: the 216 NVN functions that have call sites in the game's main program (listed in `nvn/nvn_slots.tsv`). The remaining 307 are connected to a red-reporting stub that, when called, prints `【红】NVN 未实现被调用：名字` in the log ("[red] unimplemented NVN function called: name").

Two conventions that run through the whole table:

- **GPU address = CPU address**. NVN memory pools use memory the game allocates itself, and the graphics layer creates zero-copy Metal buffers on that same memory. Any buffer address the game passes in is looked up in the memory pools' interval table and turned into "which `MTLBuffer` + offset" (`mtl_addr()`).
- **Record first, replay later**. Command buffer calls only write records into the command memory provided by the game (for the format see `nvn/nvn_obj.h`); only at submit time does `nvn/nvn_mtl.m` replay them as Metal commands.

The opt-in Simulator source profile uses host-only tokens resolved to native encoder objects/offsets. Its VM-allocated guest reservation retains the standard partition layout; pool wrapping validates the full aligned single RW region, AS ownership and actual device limit. A pool lease prevents destructive protection/discard until the actual no-copy buffer deallocator runs. Detach and completed fences drop backend references; a surviving API object still keeps its caller-owned pages leased. This path has CPU/compiler checks and a passing host-only protected-pool GPU witness from committed `f956553`: both pending GPU use and a surviving actual buffer reject destructive unmap; all 64 transformed values and canaries match; actual deallocation releases the lease before unmap succeeds. Real Guest-pool and renderer qualification remain pending. The builder and game guard do not select it yet; the default device mapping below is unchanged. Registration identity reads confine ARC interior-pointer receiver extensions to a local autorelease pool; only the Boolean result escapes. An O2 CPU annotated-buffer regression covers release inside a still-live caller pool.

The opt-in path now prepares mutable constants before creating the consuming render/compute encoder. A fresh event signal/wait separates preceding GPU writes, including untracked source aliases, from each copy batch. GPU fill and blit create per-use zero-padded private backings at offset zero, sized to the complete admitted NVN span and compiler minimum (rounded to 256 bytes, at most 64 KiB). Source offsets/spans must be four-byte aligned; unknown, overflowing, heap-backed or oversized sources fail explicitly. The native setter consumes the actual prepared object; UI matrix changes run on that copy in a subsequent GPU compute encoder. Untextured partial-screen UI coverage is explicitly rejected because its geometry is not proved without CPU reads of potentially GPU-written inputs; the dedicated iPhone-family target uses full-screen UI. Staging is capped at 128 MiB and 8,192 buffers across queued submissions. A backing is rewritten only after its consumer fence completes, and each use encodes a fresh copy. Production-path CPU recorders cover synchronization/copy/setter ordering, complete spans, zero-tail commands, budgets, matrix dispatch and fence reuse. The prior render pass and its recursive ghost draws drain before any outer prepared slots are constructed; a CPU test extracts the complete production preparation region and verifies that nested replay cannot replace an outer C1 preceding mutable CBUF bindings. A fresh diagnostic from committed `7563ead` passed the host-only `ordered-constants` case: distinct untracked aliases of owned 128 KiB VM carried GPU writes through fresh event/copy, GPU matrix adjustment and native constant arguments. All 64 values, zero tails, 16 matrix values and canaries matched across three completed submissions. Two private backings totaling 768 bytes were allocated and reused four times within the declared 1,536-byte test budget; the installed 14,363-file inventory remained exact and the owned process stopped. This qualifies that controlled alias/copy/consume topology, not real Guest pools or complete renderer limits. Actual source-alias deallocator execution was not observed by this case; its backing owner remains held by both real deallocator blocks. This does not enable the builder or game guard.

## 1. Objects

| NVN object | Metal implementation | Key points |
|---|---|---|
| Device | `MTLDevice` (unified memory required) | The device properties returned by `nvnDeviceGetInteger` are still given to the game with the Tegra X1's values (`g_devinfo` in `hle_nvn.c`) |
| MemoryPool | `newBufferWithBytesNoCopy` on game memory | Pages on Apple silicon are 16 KiB and pools are not guaranteed to be aligned to that: the start is rounded down and the end rounded up to page boundaries before the buffer is created, and the buffers of adjacent pools are allowed to overlap (`mtl_pool_add()`; the approach is verified by `metal/probe/p_nocopy.m`) |
| Buffer address (`NVNbufferAddress`) | (`MTLBuffer`, offset) | Looked up in the pools' interval table |
| Texture | `MTLTexture` | The game's packaged textures are in block-linear layout and are deswizzled at upload; format mapping and deswizzling are in `tex/`. After the game rewrites pool memory the texture is uploaded again, which is detected by the write-protection dirty page tracking of `nvn/nvn_dirty.c`. `ReadTexels`: packaged textures are deswizzled and read directly from pool memory, and textures written by the GPU are read back from the `MTLTexture` |
| TextureView | `newTextureViewWithPixelFormat:textureType:levels:slices:` | — |
| Sampler | `MTLSamplerState` | For border color Metal has only three presets (transparent black, opaque black, opaque white); the nearest one to the border color NVN gives is chosen |
| TexturePool / SamplerPool | A host-side table: descriptor number → texture / sampler | The value of a separate texture handle is the descriptor number |
| Program | One `MTLFunction` per stage | Keyed by the hash of the shader's control section and loaded from the offline-translated `<key>_b.metallib`; nothing is translated at run time. For the translation chain see the README |
| State objects (Blend / Color / ChannelMask / Multisample / Polygon / DepthStencil / VertexAttrib / VertexStream) | Fields of the render pipeline descriptor + `MTLDepthStencilState` + encoder state | The game copies these small structures by value, and the host side packs them in place with bit fields. Render pipelines and depth-stencil states are cached by state hash |
| CommandBuffer | A record stream recorded in the game's command memory | Replayed at submit time |
| Queue | Metal command queue | `SubmitCommands` = replay and submit |
| Sync | The fence value of a submission | `FenceSync` records the fence value of the most recent submission; `SyncWait` lets the caller through only after the GPU has actually completed up to that value (the completed value of an `MTLSharedEvent`). Waiting on a sync object that was never fenced returns a timeout directly |
| Event | A 32-bit value in game memory | The value is written after the GPU completes |
| Window | The game's own swapchain textures ↔ `CAMetalLayer` | `AcquireTexture` returns the index of a swapchain texture, and the wait for vertical sync happens here; `QueuePresentTexture` only puts the presentation into a queue and returns immediately, and the presentation thread draws that texture onto the drawable using the crop region given by `WindowSetCrop` |

## 2. Commands

| NVN command | Metal | Notes |
|---|---|---|
| SetRenderTargets | Ends the current render encoder and opens a new render pass | Clears before the first command in the pass are folded into the attachment's load action (load = Clear) |
| ClearColor / ClearDepthStencil | Same as above | Clears in the middle of a pass, and color clears with a partial mask or partial scissor, are not implemented and report red when encountered |
| ClearTexture / ClearTextureui | Clears one texture on its own | Some forms are not implemented and report red when encountered |
| BindProgram and the various state Bind* calls | Recorded into the current state; the pipeline is fetched as needed before the next draw | — |
| BindUniformBuffer(s) / BindStorageBuffer(s) / BindSeparateTextures / BindSeparateSamplers / BindImages | Fills the argument buffer according to the shader's reflection json | For how slot numbers correspond to the constant sections in the shader see "Shader translation chain" in the README |
| BindVertexBuffers | Vertex buffer = (`MTLBuffer`, offset) | — |
| SetViewports / SetScissor / SetDepthRange / Stencil* / SetBlendColor / SetPolygonOffsetClamp | The corresponding setting on the encoder | — |
| DrawArrays / DrawElementsInstanced | Draw / indexed draw | Metal has no quad primitive: non-indexed quads are drawn as two triangles using the shared indices 0,1,2,0,2,3; indexed quads and 8-bit indices are not implemented and report red when encountered |
| DispatchCompute | Compute encoder, with the thread group size taken from the reflection json | The 4 compute shaders embedded in the main program use the hand-written versions in `nvn/nvn_builtin.h` |
| CopyBufferToBuffer / UpdateUniformBuffer | Buffer copies inserted in order into the command stream | The data of `UpdateUniformBuffer` is copied into command memory at record time, because NVN allows the caller to modify the original data after recording |
| CopyBufferToTexture / CopyTextureToBuffer / CopyTextureToTexture | Texture copies | Some forms of texture-to-texture are not implemented and report red when encountered |
| ReportCounter / ResetCounter | The counter's value is written back after the GPU completes | The "samples passed" kind is implemented with Metal's visibility result buffer |
| SignalEvent | The event's value is written, which happens after the GPU completes | — |
| SetTexturePool / SetSamplerPool | Recorded into the command stream, noting the descriptor pool currently in use | — |

The following are empty implementations (`g_nops` in `hle_nvn.c`); calling them neither reports red nor has any effect:

`SetPatchSize`, `MultiDrawArraysIndirectCount`, `MultiDrawElementsIndirectCount`, `DispatchComputeIndirect`, `SetDepthBounds`, `DownsampleTextureView`, `WaitSync`, `SetShaderScratchMemory`, `PushDebugGroupDynamic`, `PopDebugGroup`, `InsertDebugMarkerDynamic`, `WaitEvent`, and `nvnWindowFinalize`.

## 3. Shader bindings

Switch shaders obtain their resources through a few constant sections maintained by the driver, and during replay the graphics layer fills the same contents into Metal's argument buffer. Each binding in the reflection json carries a kind (`NVN_RB_*` in `nvn/nvn_refl.h`):

| Kind | Meaning |
|---|---|
| `CBUF` | uniform buffer slot r |
| `TEX` / `SAMP` / `SAMPT` | Separate texture slot, separate sampler slot; `SAMPT` means the sampler is taken from the combined handle of the texture slot |
| `IMG` | Writable texture (image slot) |
| `TBUF` | Typed buffer (buffer texture) |
| `SBUFP` | Device pointer of a storage buffer slot |
| `UBOP` | Device pointer of a compute-stage uniform slot |
| `C1` | The shader's built-in constant section |
| `DRV0` / `DRV2` | The driver constant sections c[0] (storage buffer address table) and c[2] (texture and sampler handle table), filled in on the spot by the replay layer according to the current bindings |
| `SUPPORT` | Auxiliary constants used by the translator itself |

A texture slot with nothing bound is given a dummy texture, whose type and pixel class are taken from the reflection.

## 4. Adding a function that is not implemented yet

1. In `nvn/hle_nvn.c`, write the implementation with the `NVN(name, return type, parameters…)` macro. The macro does a signature check against `nvn/nvn_protos.h` and registers the implementation in the slot table; if the name is not in `nvn/names.txt`, the program aborts at startup.
2. If it is a command: add the record format in `nvn/nvn_obj.h`, write the recording in `hle_nvn.c`, and write the replay in `nvn/nvn_mtl.m`.
3. Add a test in `tests/`, then `make -C dm/gfx/tests run`.

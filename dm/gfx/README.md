# dm/gfx — graphics layer (NVN → Metal)

中文：[README.zh-CN.md](README.zh-CN.md)

The Switch version of the game draws with NVN (the Switch's native graphics interface). The graphics layer reimplements this interface on top of Apple's Metal: every NVN call the game makes lands here, is recorded as a command, and is replayed as Metal commands at submit time. The game's shaders are not translated at run time; they are translated offline, once, on a computer, into Metal shader libraries (when the computer has no Apple Metal compiler, the final compile step moves to the phone; see below).

For the build steps of the whole project see `README.md` and `setup.sh` in the repository root, and for dependencies see `docs/DEPENDENCIES.md`; this page covers only the graphics layer's own matters.

## How it works

### Taking over the NVN interface

- The game's main program imports only one NVN symbol, `nvnBootstrapLoader`; all other NVN functions are obtained through it by name. The host forcibly takes over this import (`nvn/hle_nvn.c`), and not a single instruction of the original graphics driver is executed.
- The game fetches the addresses of 523 names in total (`nvn/names.txt`). Each name has a thunk (`nvn/nvn_thunks.S`, a generated file): it first increments that function's call count and then jumps to the implementation.
- Of these, the 216 that have call sites in the game's main program (`nvn/nvn_slots.tsv`) all have implementations: 203 are implemented according to NVN semantics, and 13 are empty implementations (`g_nops` in `hle_nvn.c`). The remaining 307 are connected to a red-reporting stub that, when called, prints `【红】NVN 未实现被调用：名字` in the log ("[red] unimplemented NVN function called: name").
- Every implementation gets a compile-time signature check against `nvn/nvn_protos.h` (a generated file). The calling conventions of Apple arm64 and the Switch differ for integer parameters narrower than 32 bits, so on the host side `NVNboolean` parameters are always received as `uint32_t` and only the low 8 bits are examined.

### Two layers: record and replay

- **Interface layer `nvn/hle_nvn.c`**: host-side objects are stored in place in the memory the game allocates for NVN objects; the layouts are in `nvn/nvn_obj.h`, and each has a static assertion guaranteeing it does not exceed NVN's reserved size. Commands are recorded into the command memory provided by the game, in the record format of `nvn_obj.h`.
- **Replay layer `nvn/nvn_mtl.m`**: at submit time it replays the record stream as Metal commands.
  - Memory pools are created as zero-copy `MTLBuffer`s, with the GPU address equal to the CPU address, so only unified-memory devices are supported.
  - The visible effects of "GPU completion" (sync objects becoming ready, events writing their value, counters) happen only after the Metal command buffer has actually completed.
  - Pipeline states and depth-stencil states are cached by state hash; at startup, shaders and pipelines are pre-built in the background according to the warm-up manifest.
  - The game's packaged textures are in Tegra block-linear layout and are deswizzled before upload (see `tex/README.md`).
  - Presentation: the game's swapchain texture is drawn to a `CAMetalLayer`, and presentation timing is scheduled by the pacer in `nvn/nvn_pace.h`.

For which Metal object each NVN object and command lands on, see [nvn_metal_mapping.md](nvn_metal_mapping.md).

The opt-in `DM_NVN_SIMULATOR=1` source configuration uses native argument setters and actual pointer minimum/layout reflection, full NVN bound ranges and host-only buffer tokens. Classic resource tracking and fence release are independent of residency-set APIs; BF/TBDR is excluded and argument/C1 backings stay within 64 KiB. Simulator AS reservation uses vm_allocate; pool creation checks the complete rounded single VM region, RW access, retained AS ownership and device size limit. Pool leases block destructive backing changes until the actual no-copy deallocator runs. Recording submissions use their actual planned fence; without a recording submission, used pools wait for queued work before retiring. A genuinely surviving buffer reference keeps its lease alive even after GPU completion. CPU/compile checks passed. The host-only protected-reservation GPU case also passed on a fresh diagnostic from `f956553`: the pending GPU and a surviving actual buffer both prevented destructive unmap, all 64 transformed values and canaries matched, and unmap succeeded only after the actual deallocator released the lease. This covers the owned sliced-pool topology, not live Guest pools or renderer qualification. The builder does not select this configuration until complete formats, profile/PSO integration and actual renderer qualification pass. Device defaults and preflight stay unchanged. CPU binding checks run with `make -C dm/gfx/tests simulator-bindings` and write under `.tmp`. Registration identity reads confine ARC interior-pointer receiver extensions to a local autorelease pool; only the Boolean result escapes. An O2 CPU annotated-buffer regression covers release inside a still-live caller pool.

The opt-in path now prepares mutable constants before creating the consuming render/compute encoder. A fresh event signal/wait separates preceding GPU writes, including untracked source aliases, from each copy batch. GPU fill and blit create per-use zero-padded private backings at offset zero, sized to the complete admitted NVN span and compiler minimum (rounded to 256 bytes, at most 64 KiB). Source offsets/spans must be four-byte aligned; unknown, overflowing, heap-backed or oversized sources fail explicitly. The native setter consumes the actual prepared object; UI matrix changes run on that copy in a subsequent GPU compute encoder. Untextured partial-screen UI coverage is explicitly rejected because its geometry is not proved without CPU reads of potentially GPU-written inputs; the dedicated iPhone-family target uses full-screen UI. Staging is capped at 128 MiB and 8,192 buffers across queued submissions. A backing is rewritten only after its consumer fence completes, and each use encodes a fresh copy. Production-path CPU recorders cover synchronization/copy/setter ordering, complete spans, zero-tail commands, budgets, matrix dispatch and fence reuse. The prior render pass and its recursive ghost draws drain before any outer prepared slots are constructed; a CPU test extracts the complete production preparation region and verifies that nested replay cannot replace an outer C1 preceding mutable CBUF bindings. A fresh diagnostic from committed `7563ead` passed the host-only `ordered-constants` case: distinct untracked aliases of owned 128 KiB VM carried GPU writes through fresh event/copy, GPU matrix adjustment and native constant arguments. All 64 values, zero tails, 16 matrix values and canaries matched across three completed submissions. Two private backings totaling 768 bytes were allocated and reused four times within the declared 1,536-byte test budget; the installed 14,363-file inventory remained exact and the owned process stopped. This qualifies that controlled alias/copy/consume topology, not real Guest pools or complete renderer limits. Actual source-alias deallocator execution was not observed by this case; its backing owner remains held by both real deallocator blocks. This does not enable the builder or game guard.

Simulator depth fallbacks now use private tracked `Depth32Float` textures with shader-read/render-target usage. Preparation ends the preceding pass and ghost replay, then records explicit depth clear/store passes for every array slice or cube face before creating consumers. A bounded four-type cache records a fresh clear each submission; it keeps only a weak command reference and cannot publish an entry after failed preparation or beyond its command context. CPU tests cover descriptors, all clear/end pairs, allocation/encoder errors, invalid type/storage/shape, serial reuse and command release. The host-only `private-depth` case passed on a fresh ARM64/platform7 diagnostic built from committed `4a252ea`: the same cache/helper and native texture setters produced the expected 0.625 seed and zero-clear values across two completed submissions. All 32 sampled and sampler-less reads for 2D, array and all six cube faces matched, output-tail canaries stayed unchanged, and the same three texture objects were reused. Actual textures reported private tracked Depth32Float with shader-read/render-target usage; native argument length/alignment were 32/8 bytes. All 14,363 installed files matched before and after the bounded run; the process stopped without a crash and released its GPU reservation. Cube-array descriptor/clear orchestration has CPU coverage only. No CPU replaceRegion is used for simulator depth, and MSAA/writable/buffer depth fallbacks fail explicitly. This source chunk does not activate the builder or game guard; BC/formats, complete resource limits, profile/PSO/prep and real renderer/world qualification remain pending.

Simulator argument/resource resolution now finishes before render or compute consumers are created. Every use gets a fresh native encoder whose length/alignment must match the function reflection, a distinct immutable argument block, and strong resource/sampler ownership. The shared reflection encoder receives no bindings. A completed-command retirement owner drops these references before fence publication; it never retains the command. Actual arena backing is bounded globally at 64 MiB, with an additional per-submission 64 MiB encoded-byte and 8,192-bundle limit. CPU recorders cover sealing before binding, vertex/fragment/compute declarations, full spans, budgets, independent blocks, weak command ownership and reference retirement before a simulated fence publication. A fresh ARM64/platform7 diagnostic from committed `43db65c` passed the host-only `prepared-arguments` case: two independent texture/sampler argument bundles were prepared before consumers, producer references were dropped, and all 128 output words plus 64 tail canaries matched after the completed submission. Actual native argument length/alignment were 24/8 bytes, with 48 encoded bytes across the two bundles; the completion owner retired successfully. All 14,363 installed files stayed exact, the process stopped without a crash, and its GPU reservation was released. This case does not observe actual object deallocators or production draw/dispatch execution. The ownership result retains its bounded scope; the separate BC transfer component is described below.

The opt-in simulator BC transfer path now admits complete bounded source/destination regions before encoding. It ends preceding consumers, signals a fresh producer event, and waits for a separate done event on the main stream. Staging allocation starts after the producer event is reached. Separate readback and upload queues use explicitly owned resources with unretained-reference command buffers: GPU readback of linear blocks or the original GPU deswizzler produces owned bytes; the CPU decoder then fills bounded, zero-padded upload buffers. Raw-byte blits support the decoded sRGB formats without shader-write usage. The source reference is dropped after readback; staging and destination references are dropped after successful upload and before the done event is published. Input/upload staging is limited to 256 MiB and 4,096 pending jobs in production. Errors after admission terminate explicitly and never signal successful contents.

CPU recorders pass two queued jobs on one initially uncommitted main command, mutation after admission, source lifetime, actual source.contents exclusion, deferred allocation, budgets, full bounds, packaged mip/3D/array/cube orchestration and read/upload failure termination. Thirty-two independent constant-endpoint vectors cover all 16 NVN BC formats including signed/sRGB variants, padded pitches, partial 7x5 blocks, canaries and RGB BC1 alpha swizzles. The signed BC6H vector exposed upstream bcdec's signed-left-shift UB; masked unsigned sign extension now matches an independent arithmetic oracle for all 131,070 endpoint values at widths 1–16 plus 96 extreme-input checks. This defined-arithmetic correction also applies to the physical CPU fallback; physical backend selection and upload orchestration remain unchanged. The original expression still fails the sanitizer mutation control.

A fresh ARM64/platform7 diagnostic built from committed `e101c5b` passed the host-only `bc-transfers` case. Two GPU-written-source jobs for each of 16 formats matched 1,120 pixels through distinct untracked aliases, and an original GPU-deswizzle two-mip 7x5x3 packaged case matched 111 pixels. All 33 jobs completed with raw bytes, padding/canaries and staging checks passing; peak staging was 4,456 bytes, with zero pending jobs, allocated or reserved staging bytes at completion. All 14,363 installed files stayed exact; the process stopped without a crash and released the GPU reservation. This does not qualify full BC texture semantics: compressed raw-shadow/T2B/ReadTexels and format/view reinterpretation or ASTC-to-BC bridges fail explicitly; GPU-write invalidation of the existing packaged cache is still unproved. Complete format/copy semantics, maximum resource/native-layout and profile/PSO/prep/renderer/world acceptance remain prerequisites. Builder profile selection and game startup guards are unchanged.

A full derived-profile app build from committed `96e7625` passed the v3 source/resource/package checks: the app and Guest are ARM64/platform7, and all 14,080 packaged files, paired descriptors and generated inactive profile constants match. The result remains `built_unexecuted`; this artifact has not been installed or run, and its source-MSL resources have no Metal, native-layout, PSO or game qualification from the app build.

Source-only profile metadata is now independently produced and replayed by `profile_metadata.py`: it validates canonical and derived inputs, complete map/stage relations, real regenerated C1 guards and the exact ordered S/R/C subsequence. `pso_toolchain.py` freezes production C/headers and binds the actual compiler, SDK dependencies and ARM64 host/Simulator layouts while invoking the shared native codec. Historical executable identity is separate from replayable source/layout semantics; linked-byte reproducibility is not claimed. The current 6,927 map keys and 392 seed records yield 341 supported records (181 S, 12 C, 148 R); merged, specialized, BF and explicit empty-C exclusions have per-row reasons and are not reinterpreted. Exactly four output files include an atomically published descriptor binding sources, tools, genuine C1 timestamps, artifact identities, decisions and counts. Production and validation share final input admission: raw canonical/derived artifacts and input/tool/native closure are rechecked after the final complete replay, followed by exact output set/hashes before publication or a successful validation return; the renderer stage dependency is scoped to the exact `stage_of` body and labels. Native fixtures and drift negatives pass with Python 3.10 or newer. This remains source/CPU evidence. The builder now explicitly selects canonical or derived-profile resources with paired descriptor identity and the recorded Python, runs a copied frozen validation closure with full replay while preserving primary read-only inputs, and stages only base JSON/source libraries plus bound map/C1/PSO data. Both descriptors and generated identity constants with activation disabled participate in the v3 source-to-stage-to-post-link package identity chain. Preparation, cache scoping, native Metal argument/PSO and world qualification still require integration and receipts; renderer and game guards retain their existing activation conditions.

### Shader translation chain

The game's shaders are GPU machine code for the Tegra X1 (the Maxwell instruction set). The translation from this machine code to Metal Shading Language is not done on the phone; all of it happens offline:

```
Original Switch shader package
  → tools/dmsh_xlate        produces SPIR-V with Ryujinx's shader translation library (a C# tool)
  → spirv-cross             converts SPIR-V to Metal Shading Language (MSL)
  → xcrun metal / metallib  compiles into Metal shader libraries
```

Without Apple's Metal compiler (Windows, Linux, a Mac without Xcode) the last step cannot be done. `tools/nometal_run.py` lets the same chain run its first two steps as usual and puts the translated MSL source into the library files as is; a package made this way compiles the shaders once on the phone, and the system caches the compiled result. This route is used by `dm/tools/d2rm_pack.py`; see `docs/NO_XCODE.md` in the repository root.

The whole chain is driven by `tools/dmsh_build.py`, and `setup.sh` runs it for you. Key points:

- **Key**: each shader is keyed by the first 16 hexadecimal digits of the sha256 of its control section (0x880 bytes). At run time the game hands the control section to `nvnProgramSetShaders`, and the replay layer computes the same key to find the library.
- **Build outputs**: `<key>_b.metallib` (the shader library), `<key>_b.json` (reflection used by replay: each binding's kind, slot number, index within the argument buffer and so on), `<key>_b.metal` (the MSL source). Some fragment shaders additionally have `<key>_bf.metallib`, a "readable tile" version used for pass merging (see the file header of `tools/dmsh_fetch.py`). `_b_build.json` in the directory records the success or failure of each key in this run.
- **`nvn/shader_map.tsv`**: the shader map, one row per shader variant. At run time only its "key → stage (vertex / fragment / compute)" is used.
- **`nvn/shader_facts.tsv`**: the answer table for translation queries. The translator needs to know some facts that cannot be read from the machine code (the dimension type of a texture, image formats, the component types of vertex attributes and fragment outputs, a compute shader's thread group size and shared memory byte count), and this table gives the answers by key. The table ships with the repository, and building the shader libraries only reads it; the table is maintained by `tools/dmsh_facts.py`, whose file header has the details.
- **Translation chain version and the `b-<V>/` directory**: the version V is a string of 12 hexadecimal digits, obtained by hashing together the contents of the source files involved in the translation chain, the translation options and the tool fingerprints (`tools/dmsh_chain.lock`); `tools/dmsh_chain.py` computes it. Shader libraries are written into `<output directory>/b-<V>/`, and every reflection json also records V. When the host is compiled it takes V from `nvn/dmsh_chain.h`, loads only from `b-<V>/`, and checks the version in each json one by one; on a mismatch it reports red and does not load. So after changing any file on the chain, or changing a tool, the libraries must be rebuilt and the host recompiled.
  - `dmsh_chain.py`: prints V.
  - `dmsh_chain.py --check-tools`: checks that the local tools match the lock file.
  - `dmsh_chain.py --update-lock`: rewrites the lock file according to the local tools.
  - `dmsh_chain.py --header`: rewrites `nvn/dmsh_chain.h`.
  - It is normal for the local Xcode or spirv-cross version to differ from the one registered in the repository; `setup.sh` automatically re-registers according to the local tools.
- **`nvn/c1_full.tsv`**: the index list for the shaders' built-in constant section (c1), generated by `tools/c1_guard.py` scanning the translated MSL; it lists the shader keys whose "run-time index could not be proven bounded". Its first line records the `b-<V>` it corresponds to. For the shaders on the list the replay layer allocates a separate whole 64 KiB buffer for c1; when the list is missing or its version does not match, it reports red and conservatively treats all shaders this way.
- **`nvn/pso_manifest.tsv`**: the warm-up seed manifest, recording the shaders and pipelines used first after startup. The row order is the pre-build order; do not sort it.
- **Shaders embedded in the program itself**: the main program additionally contains 4 compute shaders that are not in the shader package; they were hand-written as MSL from the disassembly and are in `nvn/nvn_builtin.h`.

Binding conventions followed during translation (file header of `tools/maxwell_refs.py`):

- uniform buffer r is constant section `c[3 + r]` in the machine code;
- the handle of separate texture r is at `c[2][0x168 + 8r]`, and the handle of separate sampler r is at `c[2][0x568 + 8r]`;
- the address of storage buffer r is at `c[0][base + 16r]`, with base: vertex 0x110, compute 0x310, fragment 0x510;
- the window origin is at the top left and the depth range is 0 to 1, the same as Metal, so nothing is flipped during translation.

## Directory structure

| Location | Contents |
|---|---|
| `nvn/hle_nvn.c` | Interface layer: NVN takeover, object implementations, command recording, presentation pacing |
| `nvn/nvn_mtl.m`, `nvn/nvn_mtl.h` | Replay layer: Metal device, memory pools, textures, shader loading, pipelines, drawing, presentation |
| `nvn/nvn_prepared_arguments.h`, `nvn/nvn_prepared_arguments.m` | Owned pre-consumer argument blocks and completed-command resource/sampler retirement |
| `nvn/nvn_bc_transfer.h`, `nvn/nvn_bc_transfer.m` | Event-gated GPU readback, owned BC decoding and byte-preserving uploads for the opt-in simulator path |
| `nvn/nvn_depth_dummy.h`, `nvn/nvn_depth_dummy.m` | Private simulator depth defaults and ordered per-face clear/cache orchestration |
| `nvn/nvn_ordered_constants.h`, `nvn/nvn_ordered_constants.m` | Bounded simulator constant backings, explicit GPU ordering and UI matrix transform |
| `nvn/nvn_obj.h` | Host-side object layouts and the command record format, shared by both layers |
| `nvn/nvn_entry.S`, `nvn/nvn_thunks.S` | Entries for the unimplemented stub and the timing wrapper, per-function thunks |
| `nvn/nvn_tex.c`, `nvn/nvn_tex.h` | Storage size, alignment and per-level offsets of block-linear textures (ported from deko3d) |
| `nvn/nvn_dirty.c`, `nvn/nvn_dirty.h` | Tracks dirty pages of game memory with write protection, to decide whether texture contents have changed and need re-uploading |
| `nvn/nvn_refl.m`, `nvn/nvn_refl.h` | Converts shader reflection json into fixed-length C arrays, so that drawing only walks arrays |
| `nvn/nvn_hmap.h`, `nvn/nvn_cover.h`, `nvn/nvn_pace.h`, `nvn/nvn_pso_skey.h` | Hash table, geometric proof of full-coverage draws, presentation pacer, pipeline manifest key |
| `nvn/nvn_builtin.h` | Hand-written MSL for the 4 compute shaders embedded in the main program |
| `nvn/include/nvn.h` | NVN interface declarations (third party; for the license see the file header) |
| `nvn/*.tsv`, `nvn/names.txt`, `nvn/dmsh_chain.h` | The tables described above and the translation chain version header |
| `tex/` | Texture format mapping, deswizzling, BC decompression, see [tex/README.md](tex/README.md) |
| `metal/` | A standalone minimal Metal offscreen example, not compiled into the host, see [metal/README.md](metal/README.md) |
| `tools/` | Offline tools, see below |
| `tests/` | Unit tests |
| `hle_vi.c`, `hle_nv.c` | Glue layer for display service and graphics driver initialization: returns host static objects or does nothing |

The scripts in `tools/`; usage is written in each file's header:

| Script | Purpose |
|---|---|
| `dmsh_xlate/` | The shader translation tool (C#), which references the translation library in `dm/third_party/ryujinx` |
| `dmsh_build.py` | Drives the whole translation chain to produce the shader libraries; when the environment variable `IOSOUT=directory` is set, it also produces the iOS version |
| `dmsh_chain.py`, `dmsh_chain.lock` | Translation chain version and tool fingerprints |
| `dmsh_facts.py` | Generation and checking of the answer table `shader_facts.tsv` |
| `dmsh_fetch.py` | Generates the "readable tile" versions of fragment shaders |
| `c1_guard.py` | Generates `c1_full.tsv` |
| `dmsh_dryrun.py` | Dry-run conversion of the whole library, measuring only "can it be converted" |
| `shader_map.py`, `maxwell_refs.py` | Generates the shader map; reads resource references from the machine code |
| `nvn_slots.py`, `gen_protos.py` | Generate `nvn_slots.tsv` / `names.txt`, and `nvn_protos.h` / the thunks |
| `tbdr_budget.py`, `tbdr_load_dead.py`, `tbdr_store_dead.py`, `tbdr_pass_merge.py` | Read the `DM_NVN_PASSDUMP` log and analyze the load / store volume of each render pass's attachments per frame |
| `passgpu_top.py` | Reads the `DM_NVN_PASSGPU` output and lists GPU time by pass |
| `nometal_run.py` | Runs this translation chain on a machine without Apple's Metal compiler: shaders go into the libraries as source and are compiled on the phone |

## Building

The graphics layer has no separate library. `dm/host/Makefile` compiles `dm/gfx/*.c` and the source files under `dm/gfx/nvn/` and `dm/gfx/tex/` into the host `dmhost` by wildcard; the iOS App is built by `dm/ios/run.sh build`, which also copies the map, `pso_manifest.tsv`, `c1_full.tsv` and the `b-<V>/` shader libraries into the App. `tests/` and `metal/` do not go into the host.

The shader libraries are generated by `setup.sh`:

- the Mac version is in `$DM_ROOT/build/cache/metal_shader_cache/b-<V>/`;
- the iOS version is in `$DM_ROOT/build/ios/dmsh_b/b-<V>/`.

After changing a file on the translation chain, the order for rebuilding manually is the same as in `setup.sh`: `dmsh_chain.py --header` → `dmsh_build.py` → `c1_guard.py` → recompile the host. `$DM_ROOT` defaults to `~/dm-work`.

## Tests

```sh
make -C dm/gfx/tests run        # graphics layer unit tests
make -C dm/gfx/tex/tests run    # texture submodule unit tests; the real-data items need texture samples from both the Switch and PC versions, see tex/README.md
make -C dm/gfx/metal run        # offscreen example self-test, see metal/README.md
```

The tests in `dm/gfx/tests` compile the production code in directly and need a Metal device on the local machine; a few of them run under `MTL_DEBUG_LAYER=1` (the Metal validation layer). Most tests do not read the workspace; the exceptions are `t_refl` and `t_rt_range_ro`, which read the translated shader reflection json under `$DM_ROOT/build/cache/metal_shader_cache`, and `test_tbdr_budget.py`, which creates a temporary directory under `$DM_ROOT/run/gfx`. Main contents:

| Test | What it checks |
|---|---|
| `t_nvn` | Interface layer: fetches addresses from `nvnBootstrapLoader` the way the game does, all the way through to presentation |
| `t_builtin` | The 4 embedded compute shaders |
| `t_refl`, `t_hmap`, `t_cover`, `t_pace`, `t_pso_skey`, `t_dirty_slots` | Reflection parsing, hash table, full-coverage proof, pacer, pipeline manifest key, dirty page tracking |
| `t_deswz_gpu` | GPU deswizzling |
| `t_present_crop` | Presentation cropping |
| `t_mip_extent` | Effective size when rendering to a mip level other than level 0 |
| `t_fuse_check`, `t_reorder_chain`, `t_defer_chain`, `t_zskip`, `t_xv`, `t_ub`, `t_pfv`, `t_rt_range`, `t_rt_range_shape`, `t_rt_range_ro`, `t_rt_depth_ro` | Compile the replay layer `nvn_mtl.m` in directly and check the various optimization and diagnostic logic inside the replay layer |
| `test_tbdr_budget.py` | The parsing in `tools/tbdr_budget.py` |

## Common run-time switches

All are environment variables. The iOS App sets `DM_NVN_SHMAP` and `DM_MSL_DIR` itself at startup.

Resource locations:

| Switch | Effect |
|---|---|
| `DM_NVN_SHMAP=path` | The shader map. The default is `../gfx/nvn/shader_map.tsv` relative to the executable's directory; `c1_full.tsv` and `pso_manifest.tsv` are taken from the same directory |
| `DM_MSL_DIR=directory` | The parent directory of the shader libraries; the host loads from `b-<V>/` beneath it. When running the host on a Mac, set it to `$DM_ROOT/build/cache/metal_shader_cache` |
| `DM_PSO_MANIFEST=path` or `off` | Use a different warm-up manifest, or turn warm-up off |
| `DM_PSO_RECORD=path` | Appends the shaders and pipelines used in this run to a file, for re-recording the warm-up manifest |

Logging and capture:

| Switch | Effect |
|---|---|
| `DM_NVN_LOG=1` | Logs the creation of NVN objects |
| `DM_NVN_FRAMES=N` | Prints the call table frame by frame for the first N frames (default 3) |
| `DM_NVN_TSV=path` | Writes the per-frame call table and timings as TSV; adding `DM_NVN_TSV_CALLS=0` writes only the timing rows |
| `DM_SLOWFRAME=1` | Writes the timing breakdown into the log only for the frames that dropped; the attribution script is `dm/ios/tools/slowframe.py` |
| `DM_NVN_SHOT=frame[,frame…]:path` | Saves the swapchain texture as an image at the specified frames; `%d` in the path is replaced by the frame number |
| `DM_NVN_SHOT_OUT=WxH` | Makes the screenshot above capture the picture after upscaling to this resolution instead |
| `DM_NVN_TEXDUMP=frame:path` | Saves each color render target used in that frame as an image |
| `DM_NVN_PASSDUMP=frame` or `start-end` | Writes each render pass's attachments, samples and presentation for these frames to standard error entry by entry, for analysis by `tools/tbdr_*.py`; additionally setting `DM_NVN_PASSDUMP_ALL` logs every draw |
| `DM_NVN_PASSGPU=file` | Per-pass GPU time (requires device support for counter sampling at stage boundaries) |
| `DM_NVN_PROF=1` | Wraps the implemented NVN functions in a timing wrapper and collects the time each function takes during recording |

Comparison and testing:

| Switch | Effect |
|---|---|
| `DM_NVN_TBDR=0` | Turns off all pass optimizations in the replay layer and takes the plainest path of "all attachments attached, all loaded, all stored", for equivalence comparison |
| `DM_NVN_UNWRITTEN_DC=0` | Turns off the single item "attachments not written in this pass are not stored" |
| `DM_NVN_FUSE_CHECK=1` | Same-frame check of pass merging; logs the comparison result every time |
| `DM_TEST_NO_BC=1` | Forces the decompression path for "the GPU does not support BC compressed textures" on any machine |
| `DM_FPS=30` or `60` | Pins the target frame rate |
| `DM_PRESENT_HZ=N` | The frequency of presentation pacing (default 60); 0 means no frame limit and is for performance profiling only |

## Known limitations

The following paths are not implemented and report red in the log when reached (`RED_ONCE` in `nvn/nvn_mtl.m`):

- clears in the middle of a render pass, and color clears with a partial mask or partial scissor;
- indexed quad primitives, 8-bit indices;
- some forms of texture-to-texture copy and texture clear.

Functions listed in `g_nops`, such as `MultiDraw*IndirectCount`, `DispatchComputeIndirect`, `SetDepthBounds` and `DownsampleTextureView`, are empty implementations: calling them neither reports red nor has any effect.

# D2R Server: Protocol and Runtime Evidence

Date: 2026-10-20  
Status: companion research report; implementation feasibility remains gated  
Design: [private four-player server proposal](2026-10-20-d2r-server-design.md)  
Source baseline: `120fe55c02a5633476998a44f8c3c3c809fa48b0` (`v1.0.18`)

## Scope and conclusion

The hard-confirmed requirements are **four players per room**, modified iPhone clients, and a Linux/Docker deployment. **Every room admission imports the selected character from that phone's local save**; a server-owned permanent character roster is outside scope. Compatibility with unmodified official clients and reproduction of Battle.net services are also outside scope. The server CPU remains undecided: both x86_64 Linux and arm64 Linux must be compared. The network protocol itself is independent of CPU instruction set; executing an original game binary introduces the ISA dependency.

The source supports a credible research direction: retain the guest's game simulation as the room authority and connect modified clients through a transport owned by this project. It does not yet demonstrate a network-ready server. Existing command capture/replay proves a useful internal command boundary, while shipped-artifact inspection establishes the packaging and address mapping needed for further analysis. Neither establishes a complete wire protocol, a headless Linux game lifecycle, or four-player admission.

The preferred candidate combines two separate decisions: **guest simulation reuse** for game rules and **a new authenticated transport** for the modified clients. The implementation proposal must remain conditional on the gates below.

## Evidence classification

This report distinguishes four kinds of evidence:

- **Source fact:** executable statements or declared contracts in the baseline repository. Comments are identified separately when they provide interpretation rather than an independently reproduced result.
- **Shipped-artifact observation:** a bounded result from the signed Guest binary, recorded with an evidence identifier or a reproducible derivation manifest.
- **External author claim or contract:** primary documentation from the author of another project. This is useful precedent, not an independently executed compatibility test.
- **Inference / open question:** an architectural consequence or an unproved hypothesis requiring further work.

All original game offsets below are relative to the guest `main` image for the version used by this source baseline. They are not Mach-O file offsets, host process addresses, recovered original symbols, or portable addresses for other game builds.

## What the internal command path establishes

The current project observes and manipulates the local game's client-to-server command path:

| Anchor | Evidence and bounded meaning |
|---|---|
| `main+0x2ceab0` | Source sender calls appear in `dm/host/dm_actions.c:797–803`. Focused REA/Ghidra analysis now confirms this entry's size guard, optional progress send, duplicate-suppression branch and byte-range dispatch through the inline object `main+0x2d9f438`, virtual method `+0x30`. Its concrete transport implementation remains unknown. See the REA evidence below. |
| `main+0x5d3960` | Receive pump identified by the packet format documentation and `diag.c` comments. It has separate system-message and gameplay-command delivery paths. |
| `main+0x5d3a88` → `0x632510` | Host rewrite `SVC_HOST_C2S_DELIVER`; `diag.c:1316–1339` forwards or applies product rules. Focused REA now confirms that the receiver uses the prefixed client ID to find connection, game and player before dispatch. It advances the data pointer by four bytes while forwarding the length argument unchanged; the length/framing contract remains unknown. |
| `main+0x6e5b40` | Gameplay command dispatcher. `diag.c:1154–1177` reads game, sender unit, packet pointer, length, and tick for capture. `:1378–1394` injects recorded commands into this dispatcher. |
| `main+0x6310b0` | System-message dispatcher. `diag.c:1233–1239` captures the message without the leading local client number; `:1381–1387` reconstructs the local envelope during replay. |
| `main+0x20a4190`, `0x1daf73c` | Gameplay and system dispatch tables identified in `dm/verify/command_packet_format.md`. Their complete entries and actual coverage have not been independently recovered in this research. |

The source distinction between the dispatcher payload and receive envelope matters. `c2s_obs` reads the command number from the first payload byte. `c2s_deliver` reads it at offset four of its receive buffer (`diag.c:1325–1333`). The system capture explicitly omits a leading four-byte client number. Focused receiver decompilation independently confirms a leading client ID on that gameplay receive path. It does not prove that these four bytes are part of a remote wire frame: the receiver advances its pointer by four while passing its length argument unchanged. Copying one observed buffer shape into a network stream would therefore conflate at least two layers.

The replay implementation has narrower capabilities than a multiplayer transport:

- It runs within an existing local game, obtains one remembered game pointer and one local system client number (`diag.c:1151–1153`), and looks up units in that game's tables.
- It injects system messages before gameplay commands for the same recorded tick (`:1384–1394`).
- It depends on a locally initialized player/game lifecycle. It does not create four authenticated peer contexts or bind remote peers to their own units.
- Capture retains at most 512 payload bytes (`:1158`, `:1236`); the replay loader rejects a recorded length that does not match the available bytes (`:1416`). Separately, focused REA confirms `param_2 < 0x200` in the particular sender entry `0x2ceab0`. Neither the diagnostic ceiling nor this entry-local guard establishes a universal wire-frame maximum.
- The observation callback also invokes boss-rush, rift, pouch, and vendor feature hooks (`:1159–1163`). It is not a passive networking abstraction.

The source facts and bounded artifact observations support a candidate bridge seam. Whether it can support a complete custom transport remains an inference. Remote admission, flow control, complete framing, lifecycle completion and recipient routing remain open.

Source permalink: [capture, delivery and replay in diag.c](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/diag.c#L1138).

## S2C evidence is currently partial

The strongest source-level generic send evidence is `dm/host/dm_elysium.c:325–339`. Its executable `stash_gold_notify` function obtains a connection object from `[[player+0x10]+0xf0]`, takes the **object address** `main+0x2d7f3d8`, resolves that object's virtual method at `+0x28`, and invokes it with the object, the connection's client number and a `{begin,end}` byte range. In particular, `main+0x2d7f3d8` is the object itself, **not a pointer slot that should be dereferenced once first**. The source emits an acknowledgement when needed and a stat notification through this same method.

This is concrete source evidence for a per-client generic sending seam. The **concrete offline vtable implementation remains unknown**. The source passes stack-backed byte ranges, so the send implementation must be understood before deciding when a bridge copies, retains or releases a buffer. A virtual method call does not by itself identify the remote wire format or prove synchronous copying.

Other host features call original routines to notify the local client after authoritative inventory changes. `dm/host/dm_vault.c:171,217`, `dm_pages.c:240–244`, and `dm_pouch.c:160,179` call `main+0x642f70` with game, player and item information. These are representative original notification builders, not a recovered complete outbound codec.

Source-derived analysis anchors include **`main+0x442bc0`** for client event-message handling, confirmed by `dm/host/diag.c:414` and the observation gate in `dm/tools/patch_nso.py:641`, and `main+0x52d6f8` for client room loading. The latter appears in the rift implementation's explanation of room-layout disagreement (`dm_rift.c:964–969`). It illustrates why movement, room generation and gameplay tables must match between authority and client; it does not establish a complete S2C handler set.

Unknowns include the concrete offline send/receive methods, queue before socket/loopback delivery, complete per-recipient rules, packet-buffer ownership/lifetime, variable-length framing, compression, area initialization, full player synchronization, disconnect cleanup, and which paths rely on same-process pointers. No full bidirectional network protocol reconstruction is claimed.

Source permalinks: [generic send in dm_elysium.c](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/dm_elysium.c#L325), [vault notifications](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/dm_vault.c#L155), [client event observation gate](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/tools/patch_nso.py#L641).

## Timing and stale heartbeat documentation

The repository models the server at **25 ticks per second**: `dm/host/hle_hid.c:161` defines `SERVER_TICKS_PER_SECOND 25ull`. The scheduler interpretation in `diag.c:1433–1445` identifies `main+0x5d5120`, a 40 ms deadline increment at `0x5d51fc`, and the main loop taking one time snapshot before possible catch-up ticks. This is consistent source evidence for a 40 ms simulation cadence. It does not establish a network send rate, snapshot rate, or permissible latency budget.

There is a material documentation/code discrepancy at this baseline:

| Documented behavior | Current executable source behavior |
|---|---|
| `dm/verify/command_packet_format.md:15–22,43–45` and `tick_state_format.md:73` say recorded heartbeat `0x6d` and progress `0x6f` are injected, and the local system messages are discarded during replay. | `diag.c:1251` implements `sys_clock_msg(id)` for these two IDs. `:1254` exempts them from dropping, and `:1385` excludes their recorded copies from injection. The current replay retains the local timing messages. |

The comments immediately above the code (`diag.c:1243–1250`) explain that the messages affect acknowledgements/downstream interpolation fields and that injecting another timeline's heartbeat caused a replay disconnect. Those comments are repository analysis claims; the explicit filtering predicates are directly verified source facts. The current source predicates control any reproduction of the baseline behavior.

Consequences for design:

- Keep simulation time, per-client progress, transport liveness and frame presentation separate.
- Establish each remote peer's own timing/acknowledgement state. Reusing one local system client number for all four peers is not a supported design.
- Preserve the ordinary join/loading lifecycle when researching the bridge. Existing replay code deliberately allows lifecycle messages outside the replay window.
- Do not define the network contract from the stale replay table. Reconcile both English and Chinese packet documents if implementation work updates that contract.

This report records the discrepancy without changing the upstream verification documents.

Source permalinks: [current timing-message predicates](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/diag.c#L1241), [older packet documentation](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/verify/command_packet_format.md#L15), [scheduler explanation](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/diag.c#L1433).

## Shipped Guest inspection and the REA boundary

The signed v1.0.18 Guest artifact has SHA-256:

`9b470fb516c9c19ece5d70019c003e9140d402c1221a138e981ba871111f2a31`

Genuine REA inspection established an arm64 Mach-O and its split sections/segments. Evidence identifiers:

- `ev_af7678bcb338c57d3c065f28bcda9d02815ed476f6b4cbf438b38635977dce2c`: Mach-O inspection.
- `ev_e1a439593263a5d3115fccfa40b819ddfc32f801bf6ee9be77c863d5c8c2ae5a`: segments projection.

Private evidence is recorded in `.tmp/rea/original-guest-evidence.json`. Imports and exports were not reported exhaustively; a completed segments view is not proof that no additional logical dependencies exist.

The packaging splits executable and writable image material. `dm/host/loader.c:277–325` explains and implements remapping the signed sections back into original image-relative positions. Consequently, direct Mach-O addresses and file offsets do not preserve all original `main+offset` relationships.

The runtime research produced two **analysis-only** ELF derivatives:

| Private artifact | Provenance and limit |
|---|---|
| `.tmp/rea/v1.0.18/main.original-layout.analysis.elf` | Reconstructs original-relative layout from the three signed Guest sections. No guest bytes changed. Manifest: `.tmp/rea/v1.0.18/manifest.json`; ELF SHA-256 `d90ee8a8a49774108e0b319680912e39b4d04426f6c0da3371339d07426a7990`. |
| `.tmp/rea/v1.0.18/main.base0-relative.analysis.elf` | Applies only 60,560 `R_AARCH64_RELATIVE` relocations at synthetic base zero; 214,362 bytes changed. Manifest: `.tmp/rea/v1.0.18/base0-relative-manifest.json`; write ledger: `.tmp/rea/v1.0.18/base0-relative-writes.tsv`; ELF SHA-256 `1aa58c298d3c32dbcf8cca053021ebe26c618cd32fc852e3177192381a770ecc`. |

The helper `.tmp/rea/derive_main.py` reproduces the derivation. The manifests verify source-section readback and ELF load payloads. Twelve `SOURCE_ANCHOR_*` symbols were added as analyst annotations from source; they are not recovered guest symbols or proven function boundaries.

Neither derivative is a runnable server. Import relocation, module linkage, constructors, TLS, key pages, BSS runtime objects and ordinary initialization remain unresolved. The base-zero derivative supports static pointer/vtable analysis only.

### Focused REA decompilation completed

The initial Hopper provider timed out after 120 seconds. Its authenticated document shutdown could not be confirmed; REA reported a retained Hopper document/private runtime, and the shared application was not terminated. Separately, the first independent Ghidra pass was intentionally cancelled after approximately eight minutes of global analysis and closed cleanly; its diagnostics remain under `.tmp/rea/ghidra-attempt1/`. A changed-profile **genuine REA/Ghidra 12.1.4 session successfully decompiled the two focused functions and returned function dossiers**, then closed with no remaining resources owned by that Ghidra session. This successful cleanup does not establish closure of the earlier Hopper document.

The successful target was the separately manifested base-zero-relative ELF above. The exact analysis profile digest is `2eca5a8334fc8c54a5d443bdecc6aeabc269645610808660b871a8cab8f7ec18`; the profile and summary are `.tmp/rea/ghidra-focused-profile.json` and `.tmp/rea/ghidra-focused-findings.json`. REA 6.7.0 used Ghidra 12.1.4 and a locally built ARM64 decompiler from checksum-pinned publisher source. The original binary was not executed.

| Focused observation | Evidence identifier and private record |
|---|---|
| Sender at `main+0x2ceab0` | Pseudocode `ev_bbe5dfab494abbf3d0048faf582d156f6d45d282c0d48903b58e4985159ba099`, `.tmp/rea/ghidra-client-send.evidence.json`; dossier `ev_fa0a9d45eafa97629e0693ab127b6bc0c721f1d8f28c64bb2af731828c4d1d7e`, `.tmp/rea/ghidra-client-send-dossier.evidence.json`. |
| Receiver at `main+0x632510` | Pseudocode `ev_995499b033882d56e1eeed8f6faf1d90d663cf0a989603081e21f1b4be7deb81`, `.tmp/rea/ghidra-server-receiver.evidence.json`; dossier `ev_e192f45e1896ba5a61d7025c4b270f000550051551de12aafecf4fec0dd53f4c`, `.tmp/rea/ghidra-server-receiver-dossier.evidence.json`. |

The sender's analyzed body establishes an entry-local size condition `param_2 < 0x200`, an optional progress message `0x6f` before an ordinary command whose identifier is below `0x67`, and dispatch of a `{begin,end}` byte range through the **inline object** `main+0x2d9f438`, virtual method `+0x30`. The entry's size condition rejects the ordinary send path for lengths at or above 512. This is not a universal maximum for all messages or wire frames. The concrete virtual implementation, buffer copying and downstream framing remain unresolved.

The receiver's analyzed body reads a leading 32-bit client ID, uses the client hash rooted at `main+0x2d68610`, follows connection `+0x2e0` to the game, and resolves the game's client chain at `+0x138`. It calls the player lookup at `main+0x5d7e60` before dispatching to `main+0x6e5b40`. Crucially, it advances the incoming data pointer by four bytes but passes the original length argument unchanged. The length's inclusion/exclusion of the prefix and the surrounding queue/transport contract are **unknown**. These local lookups establish neither remote peer authentication nor safe multi-client admission.

The dossiers' caller/callee coverage is explicitly partial: the sender inventory omits 20 incoming body-reference sources and two unresolved calls; the receiver has one unresolved call. Twelve source-anchor seeds are synthetic annotations, not recovered names. Decompiler Parameter ID, Call Convention ID, Decompiler Switch Analysis, Basic Constant Reference Analyzer and Call-Fixup Installer were disabled; global signatures, references and indirect calls are therefore not an exhaustive reconstruction. FunctionManager reports sender and receiver bodies at `0x2ceab0–0x2cecef` and `0x632510–0x632723`. Its terminal/no-return flags for calls to `0x1b76f60` exclude fallthrough in the flow model; the callee's inability to return was not independently proven.

An independent shell disassembly corroborates the same focused windows, with command and output hashes in `.tmp/rea/llvm-focused/manifest.json`. That record is explicitly **shell disassembly, not REA**. No runtime/global initialization, imports, socket exchange, game execution, complete S2C codec, four-client session or headless Linux simulation has been established.

The final boundary is therefore **signed-artifact layout and two focused C2S functions analyzed; full bidirectional protocol and runtime feasibility incomplete**. No proprietary bytecode, raw decompiler text, original executables or game archives are included in this document or proposed for source control.

## Linux and four-player constraints

The existing host is Apple-specific. `loader.c:42–49` verifies a Darwin pthread TSD layout using `tpidrro_el0`; `:287,321` uses Mach VM operations. `thread.c:35–47` constructs the guest's emulated TLS/thread-local-region state separately from host thread ownership. `dm/host/Makefile:12–72` pulls in Objective-C application code, Metal, input and cloud implementations. `hle_net.c:7–47` returns unavailable/failure for network/socket operations. Linux hosting needs a platform backend and a headless lifecycle, not only a container definition.

The existing binary rewrite is also ABI-specific. `dm/tools/patch_nso.py:370–407` temporarily stores values below the current stack pointer, at offsets such as `-16` and `-24`, while borrowing registers and resolving emulated thread slots. These templates rely on the Apple red-zone convention. The generic Arm AAPCS64 instead forbids access to the inactive stack region below SP: [AAPCS64 universal stack constraints](https://github.com/ARM-software/abi-aa/blob/f44acc9198335c8a4fe0d8b0ade3ec3df328c0ad/aapcs64/aapcs64.rst#L1184), source commit 2026-10-15, retrieved 2026-10-20. A Linux port must regenerate/review templates and signal/stack behavior under its actual ABI; sharing the AArch64 ISA does not make Darwin TLS or below-SP scratch storage portable.

No measured graphics-free/null-renderer equivalence result is available in this research. `dm/host/front_mac.m:188–189` provides a windowless front-end path, which still runs the same guest; it does not establish a graphics-free authoritative server. `dm/gfx/tools/nometal_run.py` is an offline shader-tool wrapper, not a runtime null renderer. Removing presentation must preserve necessary queries, synchronization, memory effects, frame/tick pacing and lifecycle progress. That needs measurement against representative authoritative gameplay and save results, not an assumption that every graphics call can return success.

The server CPU remains an open deployment choice. Protocol messages can cross between ARM64 phones and an x86_64 or arm64 server. A source-reimplemented simulation can be compiled for either server ISA. Reusing the original Switch ARM64 simulation introduces a separate execution choice: native arm64 Linux after the platform contract is implemented, or a validated translation/emulation strategy on x86_64 Linux. A Windows x64 host engine has its own separate runtime/compatibility tradeoffs. Compare the candidates with measured tick timing and operational cost; do not infer an ARM64 server requirement merely because the phones are ARM64.

Source permalinks: [Darwin TSD check](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/loader.c#L42), [rewrite scratch storage](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/tools/patch_nso.py#L370), [windowless front end](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/host/front_mac.m#L188).

The current mods also assume one local player/game in several places:

- `diag.c:1152` holds one last game and one system client number; `:1708–1710` asserts one owner thread for diagnostic tick buffers.
- `dm_rift.c:100–116` has process-level room/progression/menu state and one player-bearing run state.
- `dm_vault.c:49–56` has one active in-memory/on-disk vault and one pending queue.
- `dm_world.c:24–25` reads a single local-player global through the guest.

One worker process per room is a useful isolation candidate for room-level globals and crashes. It does not solve the four separate player owners inside that room. Authoritative features need explicit room-, peer-, player- and character-scoped ownership. Presentation-only hooks remain on the phone; gameplay mutation belongs to the room authority. Current global state must be audited rather than mechanically exposed to four network connections.

The phone-local-character requirement also changes persistence relative to a closed-realm server. Each join needs a fresh, immutable input snapshot for that session, including the applicable character sidecars. The worker's working copy is temporary session state. Updated save results must return to the owning phone through a revision-aware transaction; character names alone cannot identify the owner because different phones may use identical names. The main proposal requires an account-level lease covering shared-stash mutations, related sidecars and cloud application, plus durable session recovery and revision-checked result delivery. The complete build-specific file manifest and save-safe boundary remain experimental gates. A server recovery journal supports delivery without becoming a permanent server character roster.

## External primary precedents

All pages below were retrieved on 2026-10-20. Author claims are not represented as tests executed by this project.

| Source | Date / license evidence | What it establishes and what it does not |
|---|---|---|
| [Blizzard beta FAQ](https://news.blizzard.com/en-us/article/23688836/play-diablo-ii-resurrectedtm-during-the-early-access-open-beta) | Published 2021-08-10 | Official TCP/IP support was removed before release. It does not prove absence of internal simulation or serialization paths. |
| [D2RLoader TCP/IP guide](https://d2rloader.net/tcp-ip.html) | Current author documentation; retrieved 2026-10-20 | Author describes modern D2R co-op with local offline characters, direct/LAN/public/unlisted games and compatibility checks. Windows PC precedent; Switch/iPhone interoperability unproved. |
| [D2RLoader changelog](https://d2rloader.net/changelog.html) | 1.3.1-beta: 2026-09-24; 1.2.0-beta: 2026-08-30 | Author reports D2R 3.3 support, room listings/heartbeats and connection fixes. This is not a verified Linux headless runtime. |
| [D2RLoader SDK README](https://github.com/D2RLoader/PluginSDK/blob/03a5af9e0feb3f95f95e148e330e01f6635950df/README.md#advanced-low-level-d2rcore-access) | Commit 2026-10-14; SDK MIT | Dedicated-server `PrepareHostEnvironment` contract and host-controlled gameplay roles. Requirements explicitly Windows x64. MIT covers the SDK, not an assumed license for the loader core. |
| [D2GS 1.13c](https://github.com/tesseract2048/d2gs/blob/b95492957fab1dae4b374eea4dffdcb6baf374d7/README.md) | Master commit 2015-01-03; README GPL-2.0-or-later | Separates D2GS networking and D2GE game logic, reusing original classic D2 binaries through LibD2Server. No D2R compatibility claim. |
| [D2GS historical author explanation](https://github.com/pvpgn/d2gs109/blob/master/README.md) | Author text dated 2001-08-13 | Historical precedent for reusing TCP/IP host simulation. Classic protocol behavior is not evidence of current D2R packet compatibility. |
| [Classic Docker/Wine deployment](https://github.com/espenmjos/d2gs) | Current README; wrapper MIT | LoD 1.14d clients, D2GS, Wine 9 and Ubuntu 24.04. Useful deployment precedent with separate component licenses; no claim of D2R or Switch support. |
| [PvPGN](https://github.com/pvpgn/pvpgn-server) | GPL-2.0; current supported-client list | Classic account/realm service precedent through D2/LoD 1.14d. The README explicitly treats D2GS as separate. Recreating its whole realm is unnecessary for the requested owned clients. |
| [OpenDiablo2 status](https://github.com/OpenDiablo2/OpenDiablo2/blob/7f92c571bf04057a7fbdfb5d25a486f7d775e3c3/docs/status.md) | Archived; last master commit 2021-10-21; GPL-3.0 | Its own March 2021 status describes Act 1 town/panels and substantial missing gameplay. It is not a complete compatible D2R server. |
| [Tristramd status](https://github.com/rookmoot/tristramd/blob/636783c00b601780a22f1ebe8b705ff9cf9047a9/README.md) | Master commit 2017-10-30; MIT | Classic account/realm work reaches create/join but remains on loading, per its own README. Not a finished simulation. |
| [diablo2-protocol](https://github.com/MephisTools/diablo2-protocol) | Last push 2020-07-30; MIT | Classic 1.13/1.14 packet codecs and client/server scaffolding. Not complete game rules or a proven D2R schema. |

No external source above establishes that classic D2 packet lengths, opcodes or save semantics can be copied unchanged into the Switch build. D2RLoader is the strongest current co-op precedent, but its public SDK is an API contract rather than the loader's transport implementation.

## Candidate comparison and recommendation

| Candidate | Benefit | Required proof |
|---|---|---|
| Reimplement protocol and complete simulation in Linux-native source | Clean runtime portability and explicit ownership | Current D2R schema plus complete maps, combat, AI, skills, items, quests, RNG and save behavior. Classic projects provide references, not a ready engine. |
| Reuse the ARM64 guest simulation headlessly on Linux | Retains detailed original rules and this mod's behavior | Linux platform contract, headless game creation, four-player lifecycle, deterministic cleanup, session save import/export. |
| Own transport around guest client/server boundaries | Fits modified clients and invitation-only rooms without official-service emulation | Complete C2S/S2C routing, per-peer state, framing, backpressure, client local-authority suppression and recovery. Combine with the guest worker for final authority. |
| Phone-hosted simulation plus Linux relay/control plane | Modern D2RLoader supplies a related host-game precedent | iOS background/termination behavior and host connectivity. It supplies only relay authority on Linux and does not meet a strict Linux-authoritative requirement. |
| Windows x64 guest/loader hosted under Wine in Linux | External dedicated-host contracts and classic Wine precedent | Actual current headless hosting and ARM64-client compatibility, runtime dependencies and loader licensing. Remains a contingency, not an established deployable option. |

Prefer the guest-worker/custom-transport combination if its proof gates pass. Treat a native simulation rewrite as a separate, substantially larger project. The worker must be demonstrated before estimating ordinary implementation tasks around the room service.

## Focused next REA questions

Use the original-layout ELF for byte-faithful code inspection and the separately manifested base-zero derivative for static pointer references. Preserve their distinction in every result. The following are bounded analysis questions on owned artifacts; they are not directions to probe official services.

| Priority | Original `main` anchors | Question / expected evidence |
|---|---|---|
| 1 | Sender `0x2ceab0`, inline object `0x2d9f438`, virtual `+0x30`; receive pump `0x5d3960`; receiver `0x632510`; dispatcher `0x6e5b40` | Extend the completed focused decompilation to the concrete offline transport and both queues. Resolve copying/lifetime and why the receiver advances by four while preserving the length. Distinguish remote framing from local client-ID envelopes. |
| 1 | System dispatch `0x6310b0`; heartbeat handler anchor `0x6317f4`; source-described join `0x67` and character chunk `0x6c` | Establish room admission, per-peer context, chunk completion and disconnect cleanup. Distinguish observed handlers from source annotations. Do not infer network authentication from local join acceptance. |
| 1 | Generic send object `0x2d7f3d8`, virtual method `+0x28`; notification `0x642f70`; client event `0x442bc0`; room load `0x52d6f8` | Resolve the concrete offline vtable method and its downstream queue; distinguish object address from pointer slot. Prove recipient selection, byte-range copying and lifetime before selecting the bridge seam. |
| 2 | Game create `0x5d0bd0`; tick `0x5d3bc0`; scheduler `0x5d5120`; main loop `0x2c1340` | Determine minimal headless lifecycle, required initialized objects, shutdown and tick deadlines. Identify presentation dependencies and effects of all clients leaving. |
| 2 | Gameplay table `0x20a4190`; system table `0x1daf73c` | Enumerate reachable handlers with lengths/validation sources where available. Mark variable-size cases and unknowns. A table count is not coverage of a usable protocol. |
| 2 | Per-player save load/validate source anchors `0x6f0c70`, `0x6fe640`; item serialization `0x581b60` | Establish complete phone-local save ingress and result egress, per-peer ownership, failure states and sidecar coordination. These are source-derived anchors until independently verified. |

Follow static analysis with a controlled two-process owned-client experiment only after lifecycle and buffer contracts are understood, then extend the acceptance criteria to four peers. A successful single-player replay or one remote action is insufficient evidence of a cooperative session.

## Evidence and decision checklist

- [x] Source baseline and shipped Guest identity recorded.
- [x] Internal C2S capture/injection, separate system-message paths and a generic per-client S2C send call found in source.
- [x] Diagnostic envelope/payload distinction and capture truncation limit recorded.
- [x] 25 Hz source timing model separated from rendering and network timing.
- [x] Stale heartbeat replay documentation compared with current executable predicates.
- [x] Signed Guest split sections and original-relative analysis derivatives have provenance.
- [x] Genuine focused REA/Ghidra sender/receiver decompilation and dossiers completed with evidence IDs; successful session closed cleanly.
- [x] Entry-local sender size guard and receiver prefix/unchanged-length observation recorded without asserting a complete wire contract.
- [x] Linux TLS/red-zone/platform dependencies and representative mod singletons identified; null-renderer equivalence explicitly unmeasured.
- [x] Four-player rooms and fresh phone-local character import on every join recorded as hard requirements; server CPU remains undecided.
- [x] Current D2RLoader co-op/dedicated-host contracts distinguished from classic precedents.
- [ ] Full C2S and S2C ownership, serialization, framing and recipient contracts independently recovered.
- [ ] Four separately owned peers admitted into one authoritative game.
- [ ] Remote clients proven to have no independent authoritative world.
- [ ] Headless/null-renderer equivalence measured and Linux worker demonstrated.
- [ ] x86_64 Linux and arm64 Linux execution strategies compared; deployment CPU chosen with evidence.
- [ ] Fresh phone-local character import on every join and transactional result return demonstrated.
- [ ] Sidecar ownership, same-name characters, reconnect and interrupted-return semantics resolved.
- [ ] Representative gameplay/mod behavior verified under four-player concurrency.

The unchecked items are feasibility gates and open questions, not completed protocol work.

# ARM64 iOS 模拟器构建

本 fork 在 `with-server` 开发模拟器与联机适配，`main` 跟进上游。工具构建独立的 `DmIOSSimulator` 应用；真机平台继续默认 platform2。

## 输入与构建

需要 Apple Silicon、Xcode 的 iPhoneSimulator SDK、XcodeGen 和 Python 3.12 或以上。输入来自同一套自有游戏和对应源码版本：main/sdk 改写映像、四份 fixup/gate 表、三个已生成的宿主数据表、私人 App 的派生界面资源，以及有完整资格清单和配套元数据的源码着色器缓存。原游戏、资源和生成应用不进入 Git。

从仓库根目录执行，输出必须是仓库 `.tmp` 内尚不存在的目录，不能与任何输入重叠：

```sh
python3 dm/ios/tools/simulator/build.py \
  --modules '<匹配的 main/sdk 运行模块目录>' \
  --app-resources '<匹配的私人 App.app>' \
  --tables '<包含三个生成表头文件的目录>' \
  --shader-cache '<已核对的源码着色器缓存目录>' \
  --shader-manifest '<源码着色器资格清单.json>' \
  --shader-metadata '<shader_map.tsv、pso_manifest.tsv、c1_full.tsv 所在目录>' \
  --out "$PWD/.tmp/simulator-build"
```

工具按每次构建的 `DEVELOPER_DIR` 选择 Xcode，生成独立 target、全新的 ARM64 platform7 Guest.framework 和 iPhoneSimulator plist，并使用普通本地签名。模拟器显式启用 `DM_NVN_M3=1` 和独立源码着色器链。此路径里名为 `.metallib` 的缓存文件保存 MSL 源码；真正的 Metal 编译仍需在模拟器中验证。

## 构建身份与一致性

构建前对整个 `dm/` 子树建立有界源码快照，包括当前分支的已跟踪文件和未跟踪源码、工具及第三方头文件，记录捕获时的 Git revision、差异摘要和逐文件身份。生成工具与编译器读取这份独立源码快照。模块、表、donor 资源、着色器缓存及清单和元数据也先形成独立只读快照。快照拒绝输入符号链接，并限制文件数量、单文件大小和总大小。装包暂存副本使用本次构建拥有的可写文件，供下述已声明的模块表与着色器元数据替换；复制完成后按原快照身份核对。

工具逐字节核对 donor 的四份 `main/sdk.fixups/gates.tsv` 与选定模块，并从 donor Guest 的六个模块节核对 main/sdk 字节及对齐填充。`PRODUCT` 相同不足以通过。运行表统一从选定模块快照暂存；`shader_map.tsv`、`pso_manifest.tsv` 和 `c1_full.tsv` 明确取自选定着色器元数据快照，覆盖 donor 的对应版本。这些关系与覆盖后的期望身份进入构建清单。

每份派生资源复制后按输入快照中预先声明的哈希核对，不把复制后的内容重新当成可信基准。生成的 native-art C 源码和构建配置绑定生成器所产生的期望字节摘要；复制的表头绑定原输入快照。Gen 中的源文件链接只允许指向这份源码快照，并绑定确切目标。

Xcode 只负责代码和自有 AppIcon；派生界面资源、运行表及源码着色器在链接完成后由工具复制进最终应用，保持字节原样，再正常签名。签名后重新核对最终资源的路径集合和哈希、Guest 的六个模块节和四份运行表、framework 元数据，并记录最终整包的逐文件清单。缺失、多出、损坏或错误来源的资源都会阻止成功清单发布。

发布 `d2r.ios-simulator-build.v2` 清单前，还会再次复核完整源码和输入快照、原输入、暂存文件集、工程描述与工具二进制。清单的成功状态是 `built_unexecuted`。静态关系检查不认证 Apple 签名；Apple SDK、系统框架和操作系统仍是已安装的外部依赖，这不是完整系统环境的归档。

构建不会启动游戏或操作手机。安装和运行检查使用仓库 `.tmp` 下独立的 CoreSimulator device set；具体设备、环境、时限和清理记录留在私有回执。原始手机存档和用户存档保持原样。

## 已验证范围

2026-10-21 的历史私人 build02 构建成功，应用及 Guest 均为 ARM64/platform7；6,927 份反射和 7,212 份源码库（含 285 个 BF 变体）完成静态核对。独立只读复核的 20 项产物检查通过，模拟器上的线程存储 508–511 槽检查通过。历史构建的 Xcode 资源阶段改写过 14 份 PNG；新工具采用上述链接后原样装包流程。旧回执保持原本的源码、产物与验证范围，不改写为新工具的结果。

当前 24 项合成测试覆盖模块与四份运行表关系、donor/模块字节变化、Mach-O 边界、设备与模拟器平台、着色器及 BF 集合、独立快照、复制期间和之后的变动、路径与大小限制、源链接目标替换，以及只读快照到可写暂存的元数据替换、复制损坏和最终资源缺失、多出或损坏。真实私人 donor 的模块和四份表通过关系检查，既有源码着色器缓存也通过当前分支的完整 BF 核对。

私人 build05 已完成 v2 构建及全部来源核对，安装后的 14,363 个文件与清单一致；线程存储检查通过，基础 Metal 画面在 4 秒内观察到约 57–60 帧。私人 build03 在编译前因暂存权限停止，build04 在编译时发现源码快照遗漏 bcdec 头文件；暂存复制已改用当前构建拥有的文件，源码快照已统一覆盖整个 `dm/` 子树，并加入对应回归检查。实际游戏启动被模拟器 GPU 的 Metal3 family 与 BC 能力检查阻止，尚未进行整套着色器编译或进入 Guest 世界。进局、保存退出和共享世界仍需各自的运行回执；构建或线程检查通过不表示联机可用。

渲染器源码现有显式 `DM_NVN_SIMULATOR=1` 配置，限定为 iOS Simulator 与经典 Metal 后端。原生 `MTLArgumentEncoder` 使用实际布局与公开 setter；缓冲绑定检查编译器反射的最小类型尺寸、NVN 请求全长、对齐和后备边界，未知范围在 setter 前拒绝。内部标记只用于宿主对象反查，资源登记与驻留集 API 分开，BF/TBDR 不适用，arena 和 c1 后备不超过 64 KiB。

该源码配置另以 vm_allocate 预留原有布局的 Guest 地址空间。每个池在创建 Metal 包装前校验完整页范围、单一可读写 VM 区域、AS 所有权及设备 maxBufferLength；池租约防止后备页被缩堆或解除映射提前丢弃。未被 GPU 解析的池可立即退役；录制中的池按对应提交栅栏退役，未录制时等已提交工作和上传完成。栅栏退役释放后端的多余引用，租约仅在实际 no-copy 缓冲的 deallocator 回调后解除；真正存活的 API 引用在 GPU 完成后仍阻止解除映射。完成通知发布前及等待返回前处理可退役引用。注册与诊断的缓冲身份检查用局部自动释放池包围 contents 读取，只让布尔结果离开，防止 ARC 的内部指针规则将缓冲额外保留到长驻外层池。

这些内存与绑定机制通过 CPU 和编译检查，尚无真实 Guest 池运行回执。构建器未选择该配置，游戏检查保持原样；uniform 有序适配、深度与 BC 格式、配套派生链的整合、预热清单和真实 GPU/游戏资格仍待完成。源码转换组件的独立 CPU 证明见后文。

## 合成测试

```sh
python3 dm/ios/tests/test_simulator.py
```

测试不需要原游戏或模拟器，临时数据留在仓库 `.tmp/simulator-tests`。源码快照测试只读取 Git 索引和当前文件，不创建提交。完整 iOS 测试入口也运行这些检查；原有需要私人夹具或生成技能资源的测试继续遵守各自的输入条件。

## Host GPU 诊断

显式启动应用并传 `-mode gpu`。应用不装载 Guest，不改变游戏前置检查，结果写入自己的 `Documents/gpu-<PID>-<UUID>.json`。`d2r.host-gpu-probe.v2` 记录实际设备名、类、registryID、architecture、Metal3/Apple2/BC/统一内存/参数缓冲层级和 Metal/AGX 加载路径，也记录公开的 `buffer.device`、`queue.device` 及 `same_as_default`。这些访问器本身不构成物理宿主 GPU 证明。

用 `DM_GPU_PROBE_CASE` 选择案例；经 simctl 启动时设置 `SIMCTL_CHILD_DM_GPU_PROBE_CASE`。缺省为 `core`；未知、空或大小写不匹配的名字在创建诊断 Metal 设备前被拒绝，并以代码 2 退出。

| 案例 | 请求的检查 |
|---|---|
| `core` | 共享缓冲、队列、64 元素直接计算和参数编码器计算 |
| `residency` | core 加驻留集创建及队列登记 |
| `nocopy-malloc` | core 加 posix_memalign 内存的零复制包装与原内存 GPU 变换回读 |
| `nocopy-vm` | core 加独立 vm_allocate 区域的相同检查 |
| `nocopy-shared` | core 加 MAP_SHARED 匿名映射的相同检查 |
| `buffer-alias` | core 加 MTLBuffer 自有共享页映射到新建区域，核对 CPU 别名写入和 GPU 变换回读 |
| `protected-pool` | core 加保护区中的 4 KiB 偏移池切片，验证单一区域包装、受控 GPU 等待期间拒绝释放、64 值回读、存活引用继续阻止释放及真实 deallocator 后解除映射 |
| `all` | 先 core，再逐项检查可选路径；可选 API 的系统断言仍会结束该进程 |

每种可选路径均先保留 core 结果。资格检查按独立应用进程分别启动案例，避免一次系统断言挡住其他案例。仅使用新建的自有 16 KiB 数据区域与 64 个 uint32；不会映射或改写 Guest 池、代码页或用户数据。

零复制案例记录分配 API、页大小与对齐、单一 VM 区域范围、读写权限和共享属性，并在包装 API 调用前保存这些结果。构造或指针相等不足以通过：GPU 必须原地变换数据，且从原先自有内存读回完整的预期结果。buffer-alias 使用 copy=false 的 vm_remap，只覆盖刚创建的自有目标区域，并核对目标地址与读写权限。映射及缓冲由所有者对象持有，GPU 完成回调继续持有它，因此 CPU 等待超时也不会提前释放在途资源。

每次 GPU 完成等待上限为 5 秒；外部启动器还须设置同步 API 在内的整个进程期限。结果分别标明 passed、unsupported、error 或 timeout，不合并成游戏可用结论。每项开始前写 pending_test，内存包装与重映射前另写分配契约；中途退出仍保留真实的未完成状态。

CPU 检查不调用 Metal 设备创建或 GPU 提交：

```sh
make -C dm/ios/tests ../../../.tmp/ios-tests/t_gpu_probe_result ../../../.tmp/ios-tests/t_gpu_probe_checkpoint ../../../.tmp/ios-tests/t_gpu_probe_memory
.tmp/ios-tests/t_gpu_probe_result
.tmp/ios-tests/t_gpu_probe_checkpoint
.tmp/ios-tests/t_gpu_probe_memory
```

它们覆盖确定输出、非法案例名、未完成报告顺序、三种分配方式、保护区与池切片、租约阻止释放和退役后解除映射、自有 VM 别名及完成回调生命周期。CPU 检查不创建 Metal 设备或提交 GPU 工作；图形层 CPU 入口还用带内部指针注解的缓冲测试 O2 释放时序，外层池在断言时保持存活。新增 protected-pool 用例尚未实际运行：它会在共享事件阻止 GPU 前进期间检查拒绝释放，放行并完成 64 值回读后保留缓冲引用，要求解除映射继续被拒绝；丢弃引用并在 5 秒内观察真实 deallocator 回调后，才允许解除映射。它们不能替代真实 Guest 内存池或渲染资格回执。

历史 diagnostic06 安装后身份匹配；实际返回 MTLSimDevice、Apple2、Tier1、Metal3/BC/统一内存为 false，共享缓冲有非零 GPU 地址。随后 malloc 后端的零复制包装触发 libxpc 断点，partial JSON 和 IPS 原样保留；该产物没有队列及计算结果。此次失败不被后续产物的成功覆盖，也没有重复运行相同 malloc 案例。

2026-10-21 的 diagnostic07 从已提交的案例选择代码生成 ARM64/platform7 产物，通过 v2 来源核对及安装后全部 14,363 个文件核对。五个案例各自启动新进程，外部时限为 30 秒；所有进程完成报告并退出，无未完成项、超时或崩溃。实际结果如下：

| 检查 | 实际结果 |
|---|---|
| core 共享缓冲与队列 | 通过；公开 buffer/queue device 均为默认 MTLSimDevice |
| core 直接计算、参数缓冲计算 | 均通过；每项 64 个预期值全部匹配，参数编码长度及对齐均为 8 |
| 独立 vm_allocate 零复制 | 原地 GPU 变换通过；从原有内存读回全部 64 个预期值 |
| MAP_SHARED 匿名 mmap 零复制 | 相同原地变换及完整回读通过 |
| MTLBuffer 自有共享页别名 | copy=false 重映射与 CPU 别名可见性通过，GPU 变换后的原区域完整回读通过 |
| 驻留集 | 创建返回 nil，报告 create_residency_set/error，未得到 NSError |

五次启动的核心计算均通过。真实能力仍是 Apple2/Tier1，Metal3 family、BC 和统一内存均为 false；architecture API 可用但值为空，Metal 映像来自模拟器运行时。这些结果只证明本次自有小缓冲和计算路径，不证明任意 malloc/Guest 池包装、驻留集、全量游戏着色器或游戏渲染可用。实际游戏前置检查保持原样。

## 模拟器着色器源码派生

`shader_profile.py` 提供 `transform_shader`、`derive_cache` 和 `validate_derived`。它读取只读的原始 MSL 源码及反射数据，仅合并绑定种类和寄存器完全相同的采样器字段，同步改写成员引用与密集参数编号，保留原计算；不支持的源码预处理、引用形状或元数据会明确失败。生成物采用包含输入、代码、选项和能力配置身份的新链，排除 BF，固定为未经过 Metal/渲染资格验证的源码结果。

全部 6,927 个基础键完成 CPU 派生与 canonical replay，移除 12,511 个重复采样器字段，最大绑定数 67→46、采样器字段 27→10。25 项合成测试、独立的原始负例及完整输出复核通过。实际 `c1_guard.py` 对原始和派生源码均生成相同的 170 个有序守卫键；派生文件的新链头由生成器真正产生。PSO 中的融合或合并条目需要相应配置过滤与生成，不能直接复制或改名冒充兼容元数据。

独立输出验证检查完整 schema、来源声明、精确键和文件集合、逐键别名证明与计数关系；调用者显式提供原始缓存、资格清单和预期键集时，还会重新计算全部转换。`derive_cache` 在发布前执行这一完整 replay。Metal 编译、原生参数编码、格式和真实游戏场景仍需后续验证，构建器尚未自动启用该派生配置。

```sh
python3 dm/ios/tests/test_shader_profile.py
```

Apple 的[模拟器 Metal 指南](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator)说明模拟器提供近似 Apple family2 的功能，且不支持片元输入读取颜色附件。[零复制缓冲 API](https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytesnocopy:length:options:deallocator:))还要求页对齐和单一 VM 区域。宿主硬件型号与模拟器机型均不能替代这些契约和计算检查。

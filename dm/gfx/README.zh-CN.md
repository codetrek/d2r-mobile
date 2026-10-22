# dm/gfx — 图形层（NVN → Metal）

English: [README.md](README.md)

游戏的 Switch 版用 NVN（Switch 的原生图形接口）画图。图形层在苹果的 Metal 上把这套接口重新实现一遍：游戏的每一次 NVN 调用落到这里，录成命令，提交时回放成 Metal 命令。游戏的着色器不在运行时翻译，而是在电脑上一次性离线翻译成 Metal 着色器库（电脑上没有苹果的 Metal 编译器时，最后的编译一步改在手机上做，见下文）。

整个项目的构建步骤见仓库根目录的 `README.zh-CN.md` 与 `setup.sh`，依赖见 `docs/DEPENDENCIES.zh-CN.md`；这里只讲图形层自己的事。

## 怎么工作

### 接管 NVN 接口

- 游戏主程序只导入一个 NVN 符号 `nvnBootstrapLoader`，其余 NVN 函数都通过它按名字取地址。宿主强制接管这个导入（`nvn/hle_nvn.c`），原版图形驱动一条指令都不执行。
- 游戏会取址的名字共 523 个（`nvn/names.txt`）。每个名字对应一个跳板（`nvn/nvn_thunks.S`，生成文件）：先给该函数的调用计数加一，再跳到实现。
- 其中游戏主程序里有调用点的 216 个（`nvn/nvn_slots.tsv`）都有实现：203 个按 NVN 语义实现，13 个是空实现（`hle_nvn.c` 的 `g_nops`）。其余 307 个接报红桩，被调到时日志里打印 `【红】NVN 未实现被调用：名字`。
- 每个实现都按 `nvn/nvn_protos.h`（生成文件）做编译期签名检查。苹果 arm64 与 Switch 的调用约定在小于 32 位的整型参数上不同，所以 `NVNboolean` 参数在宿主侧一律按 `uint32_t` 接、只看低 8 位。

### 两层：录制与回放

- **接口层 `nvn/hle_nvn.c`**：宿主侧的对象就地存在游戏给 NVN 对象分配的内存里，布局见 `nvn/nvn_obj.h`，每个都有静态断言保证不超过 NVN 的保留大小。命令按 `nvn_obj.h` 的记录格式录进游戏提供的命令内存。
- **回放层 `nvn/nvn_mtl.m`**：提交时把记录流回放成 Metal 命令。
  - 内存池建成零拷贝的 `MTLBuffer`，GPU 地址等于 CPU 地址，所以只支持统一内存设备。
  - 「GPU 完成」的可见效果（同步对象就绪、事件写值、计数器）只在 Metal 命令缓冲真正完成之后发生。
  - 管线状态、深度模板状态按状态哈希缓存；启动时按预热清单在后台预建着色器与管线。
  - 游戏打包贴图是 Tegra 块线性排布，上传前解排布（见 `tex/README.zh-CN.md`）。
  - 出图：游戏的交换链贴图画到 `CAMetalLayer`，出图节拍由 `nvn/nvn_pace.h` 的节拍器排。

各 NVN 对象与命令落到 Metal 的哪个对象，见 [nvn_metal_mapping.zh-CN.md](nvn_metal_mapping.zh-CN.md)。

显式 `DM_NVN_SIMULATOR=1` 源码配置使用原生参数 setter、实际指针最小类型/布局反射、完整 NVN 范围和宿主缓冲标记。经典资源登记及栅栏释放与驻留集 API 分开，BF/TBDR 不适用，参数/c1 后备不超过 64 KiB。模拟器用 vm_allocate 预留 AS；池创建核对完整页范围、单一可读写 VM 区域、AS 所有权和设备上限。租约阻止后备页在池退役前被丢弃；录制中的池按实际计划栅栏退役，未录制时等已提交工作后退役，仍存活的缓冲引用在 GPU 完成后继续保留租约。CPU/编译检查通过。由 `f956553` 构建的新诊断产物也通过 host-only 保护区 GPU 检查：待执行 GPU 和仍存活的实际缓冲均阻止破坏性解除映射，64 个变换值及周边保护数据匹配，真实 deallocator 解除租约后才成功解除映射。该结果覆盖自有池切片拓扑，真实 Guest 池和渲染资格仍需验证。构建器须待完整格式、派生配置/PSO 整合和真实渲染资格通过后选择此配置；设备默认和启动检查保持原样。从根目录运行 `make -C dm/gfx/tests simulator-bindings` 可执行 CPU 绑定检查，产物留在 `.tmp`。注册身份检查在局部自动释放池内读取 contents，只返回布尔值，避免 ARC 将内存池包装对象额外保留到长驻调用线程的外层池。O2 CPU 检查用同样的内部指针注解验证外层池仍存活时的释放时序。

该显式配置现会在消费方渲染/计算编码器创建前准备可变常量。每批使用全新的事件 signal/wait 分隔此前 GPU 写入与复制，也覆盖未自动追踪的源缓冲别名；GPU fill 和 blit 按完整 NVN 范围与编译器最小类型尺寸生成每次使用独立的补零私有后备，长度向上对齐 256 字节、最多 64 KiB，绑定偏移为零。源偏移和长度须按 4 字节对齐；未知、越界、heap 后备或超限来源明确失败。原生 setter 直接消费准备好的对象，界面矩阵在该副本上由后续 GPU 计算编码器调整。局部界面的无贴图覆盖判断尚无法在不读取潜在 GPU 写入数据的前提下证明，因此明确拒绝；独立 iPhone-family 目标使用全屏界面。所有在途提交的暂存总量限制为 128 MiB、8,192 个缓冲；只有消费栅栏完成后的后备才可再次写入，每次使用仍重新记录复制。生产路径 CPU 记录器验证同步/复制/setter 顺序、完整范围、补零指令、预算、矩阵派发和栅栏复用。准备外层参数槽之前，先结束原渲染通道并完成其中递归的跟手图绘制；CPU 检查抽取完整的生产准备代码，验证嵌套回放不能覆盖外层先于可变 CBUF 绑定的 C1。由已提交 `7563ead` 构建的新诊断产物通过 host-only ordered-constants 实测：128 KiB 自有 VM 的两个未自动追踪别名，经 GPU 写入、全新事件同步与复制、GPU 矩阵调整及原生常量参数消费，连续三个完成提交中的 64 个值、零尾部、16 个矩阵值和周边保护数据全部匹配。两个私有后备合计 768 字节，在声明的 1,536 字节测试预算内复用四次；14,363 个安装文件保持一致，进程已停止。该结果限定于自有别名/复制/消费拓扑，真实 Guest 池和完整渲染资源上限仍需验证。该案例未观察源别名的实际 deallocator 执行；后备所有者由两个真实 deallocator block 持有。构建器和游戏检查尚未启用该配置。

模拟器深度默认纹理现采用私有、自动追踪的 Depth32Float 后备，以及 shader-read/render-target 用途。准备阶段先结束前一通道和跟手图回放，再在消费编码器创建前，为每个数组切片或立方体面记录显式清除与保存通道。有界缓存最多持有四类纹理，每个新提交重新记录清除；命令缓冲仅被弱引用，准备失败或离开对应命令上下文后不会提供可用条目。CPU 检查覆盖描述符、所有清除/end 配对、分配和编码失败、错误类型/存储/形状、提交序号复用及命令释放。由已提交 `4a252ea` 构建的新 ARM64/platform7 诊断产物通过 host-only private-depth 实测：同一缓存/辅助函数及原生纹理 setter 在两个完成提交中产生预期的 0.625 种子值和清零值。2D、数组及立方体六个面的采样和无采样器读取共 32 个值全部匹配，输出尾部保护数据不变，三个纹理对象得到复用。实际纹理为私有、自动追踪的 Depth32Float，具有 shader-read/render-target 用途；原生参数编码长度与对齐分别为 32、8 字节。限时运行前后全部 14,363 个安装文件一致，应用无崩溃并已停止，自有 GPU 预约已释放。立方体数组目前仅有描述符/清除编排的 CPU 检查。模拟器深度不使用 CPU replaceRegion，MSAA、可写及缓冲深度默认纹理明确失败。该源码尚未启用构建配置或游戏检查；BC/格式、完整资源上限、配置/PSO/预热及真实渲染和世界资格仍待完成。

模拟器参数和资源解析现会在渲染或计算消费编码器创建前完成。每次使用都创建与函数反射长度/对齐一致的新原生编码器、独立且不再改写的参数块，并强引用所需资源与采样器；共享的反射编码器不接收绑定。完成命令对应的退役所有者在发布栅栏之前丢弃这些引用，自身不强持有命令缓冲。实际 arena 后备全局限制为 64 MiB，每个提交另限制 64 MiB 编码字节和 8,192 个参数包。CPU 记录器覆盖先封存后绑定、顶点/片元/计算声明、完整范围、预算、独立参数块、命令弱引用及模拟栅栏发布前的引用退役。由已提交 `43db65c` 构建的新 ARM64/platform7 诊断产物通过 host-only prepared-arguments 实测：消费方创建前先准备两组独立的纹理/采样器参数，丢弃生产方引用后，在完成提交中核对的 128 个输出值及 64 个尾部保护值全部匹配。实际原生编码长度/对齐为 24/8 字节，两组共 48 字节，完成所有者成功退役。前后全部 14,363 个安装文件一致，进程无崩溃并已停止，GPU 预约已释放。该案例没有观察实际对象的 deallocator，也不覆盖生产绘制/派发执行。所有权结果的范围保持不变；BC 传输组件的独立源码与检查状态如下。

显式模拟器 BC 传输路径现会在编码前检查完整且有界的源和目标区域。先结束前面的消费编码器，在主命令流记录新的生产方事件，再等待独立的完成事件；生产方事件到达后才分配暂存区。读取和上传分别使用独立队列、显式拥有资源的不保留引用命令缓冲：线性块通过 GPU 读回，打包纹理通过原有 GPU 解排布，得到自有字节后才由 CPU 解码，并填入有界、清零填充的上传缓冲。解压后的 sRGB 格式使用原始字节 blit，不要求 shader-write 用途。读回完成后丢弃源引用，成功上传后先丢弃暂存和目标引用，再发布完成事件；生产路径限制 256 MiB 输入/上传暂存和 4,096 个待完成请求。接受后的错误明确终止，不会把失败内容标记为成功。

CPU 记录器通过同一个尚未提交的主命令中的两个请求、接受后源修改、源生命周期、禁止读取 source.contents、延后分配、预算、完整范围、打包多级/3D/数组/立方体编排，以及读取/上传失败终止检查。32 组独立固定端点覆盖全部 16 种 NVN BC 格式，包含有符号/sRGB、带填充行距、7x5 不满块边缘、保护数据和 RGB BC1 的 alpha 重映射。有符号 BC6H 端点暴露了上游 bcdec 的有符号左移未定义行为；有界无符号符号扩展已通过独立算术判据，覆盖 1–16 位宽全部 131,070 个值及 96 个极值输入。此行为有定义的算术修正也影响真机 CPU 解压路径；真机后端选择和上传编排不变。恢复原运算的负对照仍会被检查器拒绝。

由已提交 `e101c5b` 构建的新 ARM64/platform7 诊断产物通过 host-only bc-transfers 实测。16 种格式各两个由 GPU 写入、经独立不自动追踪别名读取的请求匹配全部 1,120 个像素；原 GPU 解排布的两级 mip、7x5x3 打包案例匹配全部 111 个像素。33 个请求全部完成，原始字节、填充/保护数据及暂存检查通过；峰值暂存 4,456 字节，结束时待处理请求、已分配及预留暂存字节均为零。前后全部 14,363 个安装文件一致，进程无崩溃并已停止，自有 GPU 预约已释放。这尚未覆盖完整 BC 语义：压缩原字节影子存储、T2B/ReadTexels、格式/视图重解释和 ASTC 到 BC 桥接均明确失败，现有打包纹理缓存对 GPU 写入的失效处理仍未证明。完整格式/复制语义、最大资源和原生布局、配置/PSO/预热整合及真实渲染/世界资格仍为启用前提；构建器配置选择与游戏启动检查不变。

源码配置元数据现由 `profile_metadata.py` 独立生产和重放验证：明确核对原始与派生配置、完整映射及阶段，真实重新生成并比较 C1，按原始顺序保留支持的 S/R/C 行体。`pso_toolchain.py` 冻结实际生产 C/头文件，以明确的编译器、SDK 依赖和 ARM64 主机/模拟器布局检查驱动共用原生编解码器；二进制历史身份与可重放的源码/布局关系分开记录，不声称链接产物逐字节重现。当前 6,927 个映射键和 392 条种子得到 341 条支持记录（181 S、12 C、148 R）；合并、特化、BF 及明确的空 C 逐行记录排除原因，不改变其描述。输出精确四个文件，描述文件原子发布，绑定来源、工具、真实 C1 时间戳、输出身份、决策和计数。生产与验证共用最终输入准入，在最后一次完整重放后重新核对原始/派生文件及输入/工具/原生闭包，再检查精确输出集合和哈希，才发布描述文件或返回验证成功；阶段依赖限定于 `stage_of` 的精确函数体与标签。Python 3.10 以上的原生夹具及漂移负例通过；此结果仅为源码/CPU 证明。构建器现通过显式 canonical/derived-profile 模式、成对描述身份及记录的 Python 选择资源；隔离执行冻结验证闭包并完整重放，原始只读输入不变，仅暂存基础 JSON/源码库和绑定的映射/C1/PSO。两个描述文件与禁用激活的生成常量进入 v3 源→暂存→链接后整包身份链。预热、缓存隔离、Metal 参数/PSO 和游戏世界仍需整合及运行验证；渲染配置与游戏检查保持原来的启用条件。

### 着色器翻译链

游戏的着色器是 Tegra X1 的 GPU 机器码（Maxwell 指令集）。从这种机器码到 Metal 着色语言的翻译不在手机上做，全部离线完成：

```
Switch 原版着色器包
  → tools/dmsh_xlate        用 Ryujinx 的着色器翻译库出 SPIR-V（C# 工具）
  → spirv-cross             SPIR-V 转 Metal 着色语言（MSL）
  → xcrun metal / metallib  编成 Metal 着色器库
```

没有苹果的 Metal 编译器时（Windows、Linux、没装 Xcode 的 Mac），最后一步做不了。`tools/nometal_run.py` 让同一条链照常跑完前两步，把翻译出的 MSL 源码原样放进库文件；这样做出的包在手机上把着色器编译一次，系统会缓存编好的结果。这条路由 `dm/tools/d2rm_pack.py` 使用，见仓库根目录的 `docs/NO_XCODE.zh-CN.md`。

整条链由 `tools/dmsh_build.py` 驱动，`setup.sh` 会替你跑。要点：

- **键**：每个着色器以它的控制段（0x880 字节）的 sha256 前 16 位十六进制为键。运行时游戏把控制段交给 `nvnProgramSetShaders`，回放层算出同一个键去找库。
- **产物**：`<键>_b.metallib`（着色器库）、`<键>_b.json`（回放用的反射：各绑定的种类、槽号、在参数缓冲里的序号等）、`<键>_b.metal`（MSL 源）。部分片元着色器另有 `<键>_bf.metallib`，是「可读 tile」版本，供通道合并用（见 `tools/dmsh_fetch.py` 文件头）。目录里的 `_b_build.json` 记本次每个键的成败。
- **`nvn/shader_map.tsv`**：着色器映射表，每个着色器变体一行。运行时只用其中「键 → 阶段（顶点 / 片元 / 计算）」。
- **`nvn/shader_facts.tsv`**：翻译查询的作答表。翻译器需要知道一些机器码里读不出的事实（贴图的维度类型、图像格式、顶点属性与片元输出的分量类型、计算着色器的线程组大小与共享内存字节数），这张表按键给出答案。表随仓库，出着色器库只读这张表；表由 `tools/dmsh_facts.py` 维护，文件头有说明。
- **翻译链版本与 `b-<V>/` 目录**：版本 V 是一串 12 位十六进制，由翻译链涉及的源文件内容、翻译选项和工具指纹（`tools/dmsh_chain.lock`）一起哈希得出，`tools/dmsh_chain.py` 负责计算。着色器库写进 `<输出目录>/b-<V>/`，每个反射 json 里也记着 V。宿主编译时从 `nvn/dmsh_chain.h` 取 V，只从 `b-<V>/` 加载，并逐个核对 json 里的版本；对不上就报红、不加载。所以改了链上任何一个文件、或换了工具，都要重新出库并重编宿主。
  - `dmsh_chain.py`：打印 V。
  - `dmsh_chain.py --check-tools`：核对本机工具与锁文件一致。
  - `dmsh_chain.py --update-lock`：按本机工具重写锁文件。
  - `dmsh_chain.py --header`：重写 `nvn/dmsh_chain.h`。
  - 本机的 Xcode 或 spirv-cross 版本与仓库登记的不同是正常的，`setup.sh` 会自动按本机工具重新登记。
- **`nvn/c1_full.tsv`**：着色器自带常数段（c1）的下标清单，由 `tools/c1_guard.py` 扫描翻译出的 MSL 生成，列出「运行时下标没能证明有界」的着色器键。首行记着它对应的 `b-<V>`。回放层对清单里的着色器给 c1 单独分配整块 64 KiB 缓冲；清单缺失或版本对不上时报红，并对全部着色器都这样保守处理。
- **`nvn/pso_manifest.tsv`**：预热种子清单，记启动后最先用到的着色器与管线，行序就是预建顺序，不要排序。
- **程序本体内嵌的着色器**：主程序里另有 4 个计算着色器不在着色器包里，按反汇编手写成 MSL，在 `nvn/nvn_builtin.h`。

翻译时遵循的绑定约定（`tools/maxwell_refs.py` 文件头）：

- uniform 缓冲 r 在机器码里是常量段 `c[3 + r]`；
- 分离贴图 r 的句柄在 `c[2][0x168 + 8r]`，分离采样器 r 的句柄在 `c[2][0x568 + 8r]`；
- 存储缓冲 r 的地址在 `c[0][基址 + 16r]`，基址：顶点 0x110、计算 0x310、片元 0x510；
- 窗口原点在左上、深度范围 0 到 1，与 Metal 一致，翻译时不翻转。

## 目录结构

| 位置 | 内容 |
|---|---|
| `nvn/hle_nvn.c` | 接口层：接管 NVN、对象实现、命令录制、出图节拍 |
| `nvn/nvn_mtl.m`、`nvn/nvn_mtl.h` | 回放层：Metal 设备、内存池、贴图、着色器加载、管线、绘制、出图 |
| `nvn/nvn_prepared_arguments.h`、`nvn/nvn_prepared_arguments.m` | 消费前拥有的参数块，以及完成命令后的资源/采样器退役 |
| `nvn/nvn_bc_transfer.h`、`nvn/nvn_bc_transfer.m` | 显式模拟器路径的事件同步 GPU 读回、自有 BC 解码及原始字节上传 |
| `nvn/nvn_depth_dummy.h`、`nvn/nvn_depth_dummy.m` | 模拟器私有深度默认纹理及逐面清除/缓存编排 |
| `nvn/nvn_ordered_constants.h`、`nvn/nvn_ordered_constants.m` | 有界模拟器常量后备、显式 GPU 顺序和界面矩阵变换 |
| `nvn/nvn_obj.h` | 宿主侧对象布局与命令记录格式，两层共用 |
| `nvn/nvn_entry.S`、`nvn/nvn_thunks.S` | 未实现桩与计时包装的入口、逐函数跳板 |
| `nvn/nvn_tex.c`、`nvn/nvn_tex.h` | 块线性贴图的存储尺寸、对齐、各级偏移（移植自 deko3d） |
| `nvn/nvn_dirty.c`、`nvn/nvn_dirty.h` | 用写保护跟踪游戏内存的脏页，判断贴图内容是否变了需要重传 |
| `nvn/nvn_refl.m`、`nvn/nvn_refl.h` | 着色器反射 json 转成定长 C 数组，绘制时只遍历数组 |
| `nvn/nvn_hmap.h`、`nvn/nvn_cover.h`、`nvn/nvn_pace.h`、`nvn/nvn_pso_skey.h` | 哈希表、全覆盖绘制的几何证明、出图节拍器、管线清单键 |
| `nvn/nvn_builtin.h` | 主程序内嵌的 4 个计算着色器的手写 MSL |
| `nvn/include/nvn.h` | NVN 接口声明（第三方，许可证见文件头） |
| `nvn/*.tsv`、`nvn/names.txt`、`nvn/dmsh_chain.h` | 上文讲的各张表与翻译链版本头 |
| `tex/` | 贴图格式映射、解排布、BC 解压，见 [tex/README.zh-CN.md](tex/README.zh-CN.md) |
| `metal/` | 独立的最小 Metal 离屏示例，不编进宿主，见 [metal/README.zh-CN.md](metal/README.zh-CN.md) |
| `tools/` | 离线工具，见下 |
| `tests/` | 单元测试 |
| `hle_vi.c`、`hle_nv.c` | 显示服务与图形驱动初始化的胶水层：返回宿主静态对象或空操作 |

`tools/` 里的脚本，用法都写在各自文件头：

| 脚本 | 用途 |
|---|---|
| `dmsh_xlate/` | 着色器翻译工具（C#），引用 `dm/third_party/ryujinx` 里的翻译库 |
| `dmsh_build.py` | 驱动整条翻译链出着色器库；设环境变量 `IOSOUT=目录` 时同时出 iOS 版 |
| `dmsh_chain.py`、`dmsh_chain.lock` | 翻译链版本与工具指纹 |
| `dmsh_facts.py` | 作答表 `shader_facts.tsv` 的生成与核对 |
| `dmsh_fetch.py` | 生成片元着色器的「可读 tile」版本 |
| `c1_guard.py` | 生成 `c1_full.tsv` |
| `dmsh_dryrun.py` | 全库干转，只量「能不能转」 |
| `shader_map.py`、`maxwell_refs.py` | 生成着色器映射表；从机器码读资源引用 |
| `nvn_slots.py`、`gen_protos.py` | 生成 `nvn_slots.tsv` / `names.txt`、`nvn_protos.h` / 跳板 |
| `tbdr_budget.py`、`tbdr_load_dead.py`、`tbdr_store_dead.py`、`tbdr_pass_merge.py` | 读 `DM_NVN_PASSDUMP` 的日志，分析每帧各渲染通道附件的读入 / 写回量 |
| `passgpu_top.py` | 读 `DM_NVN_PASSGPU` 的输出，按通道列 GPU 时间 |
| `nometal_run.py` | 在没有苹果 Metal 编译器的机器上跑这条翻译链：着色器以源码进库，到手机上再编 |

## 构建

图形层没有单独的库。`dm/host/Makefile` 按通配把 `dm/gfx/*.c`、`dm/gfx/nvn/` 与 `dm/gfx/tex/` 下的源文件编进宿主 `dmhost`；iOS App 由 `dm/ios/run.sh build` 构建，同时把映射表、`pso_manifest.tsv`、`c1_full.tsv` 和 `b-<V>/` 着色器库拷进 App。`tests/` 与 `metal/` 不进宿主。

着色器库由 `setup.sh` 生成：

- Mac 版在 `$DM_ROOT/build/cache/metal_shader_cache/b-<V>/`；
- iOS 版在 `$DM_ROOT/build/ios/dmsh_b/b-<V>/`。

改了翻译链上的文件后，手动重出的顺序与 `setup.sh` 里相同：`dmsh_chain.py --header` → `dmsh_build.py` → `c1_guard.py` → 重编宿主。`$DM_ROOT` 缺省是 `~/dm-work`。

## 测试

```sh
make -C dm/gfx/tests run        # 图形层单测
make -C dm/gfx/tex/tests run    # 贴图子模块单测；真数据项要 Switch 与 PC 两版的贴图样本，见 tex/README.zh-CN.md
make -C dm/gfx/metal run        # 离屏示例自测，见 metal/README.zh-CN.md
```

`dm/gfx/tests` 的测试直接编入生产代码，需要本机有 Metal 设备；其中几项在 `MTL_DEBUG_LAYER=1`（Metal 校验层）下运行。多数测试不读工作区；例外是 `t_refl` 与 `t_rt_range_ro` 要读 `$DM_ROOT/build/cache/metal_shader_cache` 下翻译好的着色器反射 json，`test_tbdr_budget.py` 会在 `$DM_ROOT/run/gfx` 下建临时目录。主要内容：

| 测试 | 核什么 |
|---|---|
| `t_nvn` | 接口层：照游戏的用法从 `nvnBootstrapLoader` 取址，一路走到出图 |
| `t_builtin` | 4 个内嵌计算着色器 |
| `t_refl`、`t_hmap`、`t_cover`、`t_pace`、`t_pso_skey`、`t_dirty_slots` | 反射解析、哈希表、全覆盖证明、节拍器、管线清单键、脏页跟踪 |
| `t_deswz_gpu` | GPU 解排布 |
| `t_present_crop` | 出图裁切 |
| `t_mip_extent` | 渲染到非第 0 级 mip 时的有效尺寸 |
| `t_fuse_check`、`t_reorder_chain`、`t_defer_chain`、`t_zskip`、`t_xv`、`t_ub`、`t_pfv`、`t_rt_range`、`t_rt_range_shape`、`t_rt_range_ro`、`t_rt_depth_ro` | 直接编入回放层 `nvn_mtl.m`，核回放层内部的各项优化与诊断逻辑 |
| `test_tbdr_budget.py` | `tools/tbdr_budget.py` 的解析 |

## 常用运行时开关

都是环境变量。iOS App 启动时自己设好 `DM_NVN_SHMAP` 与 `DM_MSL_DIR`。

资源位置：

| 开关 | 作用 |
|---|---|
| `DM_NVN_SHMAP=路径` | 着色器映射表。缺省是可执行文件目录下的 `../gfx/nvn/shader_map.tsv`；`c1_full.tsv` 与 `pso_manifest.tsv` 取同目录 |
| `DM_MSL_DIR=目录` | 着色器库的上级目录，宿主从其下的 `b-<V>/` 加载。在 Mac 上跑宿主时设为 `$DM_ROOT/build/cache/metal_shader_cache` |
| `DM_PSO_MANIFEST=路径` 或 `off` | 换一份预热清单，或关掉预热 |
| `DM_PSO_RECORD=路径` | 把本次运行用到的着色器与管线追加记到文件，用来重录预热清单 |

日志与抓取：

| 开关 | 作用 |
|---|---|
| `DM_NVN_LOG=1` | 记录 NVN 对象的创建 |
| `DM_NVN_FRAMES=N` | 前 N 帧逐帧打印调用表（缺省 3） |
| `DM_NVN_TSV=路径` | 每帧调用表与计时写成 TSV；再加 `DM_NVN_TSV_CALLS=0` 只写计时行 |
| `DM_SLOWFRAME=1` | 只把掉帧那几帧的计时分项写进日志；归因脚本是 `dm/ios/tools/slowframe.py` |
| `DM_NVN_SHOT=帧号[,帧号…]:路径` | 在指定帧把交换链贴图存成图片，路径里的 `%d` 换成帧号 |
| `DM_NVN_SHOT_OUT=宽x高` | 上面的截图改截放大到该分辨率后的画面 |
| `DM_NVN_TEXDUMP=帧号:路径` | 把该帧用过的颜色渲染目标逐张存图 |
| `DM_NVN_PASSDUMP=帧号` 或 `起-止` | 把这些帧每个渲染通道的附件、采样、出图逐条写到标准错误，供 `tools/tbdr_*.py` 分析；再设 `DM_NVN_PASSDUMP_ALL` 则每次绘制都记 |
| `DM_NVN_PASSGPU=文件` | 逐通道 GPU 时间（需要设备支持阶段边界的计数采样） |
| `DM_NVN_PROF=1` | 给已实现的 NVN 函数套计时包装，统计录制期各函数耗时 |

对照与测试：

| 开关 | 作用 |
|---|---|
| `DM_NVN_TBDR=0` | 关掉回放层全部通道优化，走「附件全挂、全读入、全写回」的最朴素路径，用来做等价对照 |
| `DM_NVN_UNWRITTEN_DC=0` | 关掉「本通道没写的附件不写回」这一项 |
| `DM_NVN_FUSE_CHECK=1` | 通道合并的同帧核对，逐次把比对结果记进日志 |
| `DM_TEST_NO_BC=1` | 在任何机器上强制走「显卡不支持 BC 压缩贴图」的解压路径 |
| `DM_FPS=30` 或 `60` | 钉住目标帧数 |
| `DM_PRESENT_HZ=N` | 出图节拍的频率（缺省 60）；0 表示不限帧，只用于性能剖析 |

## 已知限制

下面这些路径没有实现，走到会在日志里报红（`nvn/nvn_mtl.m` 里的 `RED_ONCE`）：

- 渲染通道中途的清除、带部分掩码或部分剪裁的清色；
- 带索引的四边形图元、8 位索引；
- 部分形态的贴图到贴图拷贝与清贴图。

`MultiDraw*IndirectCount`、`DispatchComputeIndirect`、`SetDepthBounds`、`DownsampleTextureView` 等列在 `g_nops` 里的函数是空实现，调用不报红也不生效。

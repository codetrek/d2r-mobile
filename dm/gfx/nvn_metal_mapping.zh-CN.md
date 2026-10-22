# NVN → Metal 对象映射

English: [nvn_metal_mapping.md](nvn_metal_mapping.md)

这份文档列出 NVN（Switch 的原生图形接口）的各类对象与命令，在 D2R Mobile 的图形层里分别落到 Metal 的什么上。图形层的整体结构见 [README.zh-CN.md](README.zh-CN.md)。

范围：游戏主程序里有调用点的 216 个 NVN 函数（清单在 `nvn/nvn_slots.tsv`）。其余 307 个接报红桩，被调到时日志打印 `【红】NVN 未实现被调用：名字`。

两条贯穿全表的约定：

- **GPU 地址 = CPU 地址**。NVN 的内存池用的是游戏自己分配的内存，图形层在同一段内存上建零拷贝的 Metal 缓冲。游戏传来的任何缓冲地址，都用内存池的区间表反查成「哪个 `MTLBuffer` + 偏移」（`mtl_addr()`）。
- **先录后放**。命令缓冲的调用只是把记录写进游戏提供的命令内存（格式见 `nvn/nvn_obj.h`），到提交时才由 `nvn/nvn_mtl.m` 回放成 Metal 命令。

显式模拟器源码配置把宿主缓冲标记解析成原生编码器对象/偏移；Guest 预留使用 vm_allocate 并保持原有分区。池包装核对完整对齐范围、单一可读写区域、AS 所有权和实际设备上限；租约防止后备页在真实 no-copy 缓冲的 deallocator 回调前被破坏性保护或丢弃；分离及栅栏完成只释放后端引用，存活的 API 对象仍保留租约。CPU/编译检查已通过；已提交 `f956553` 的新诊断产物通过 host-only 保护池 GPU 检查：待执行 GPU 和存活的实际缓冲均阻止破坏性解除映射，64 个变换值及周边保护数据匹配，实际释放回调解除租约后才成功解除映射。真实 Guest 池和渲染资格仍待完成。构建器及游戏检查尚未选择此配置，下述设备默认映射保持原样。注册身份检查在局部自动释放池内读取 contents，只返回布尔值，避免 ARC 将内存池包装对象额外保留到长驻调用线程的外层池。O2 CPU 检查用同样的内部指针注解验证外层池仍存活时的释放时序。

该显式配置现会在消费方渲染/计算编码器创建前准备可变常量。每批使用全新的事件 signal/wait 分隔此前 GPU 写入与复制，也覆盖未自动追踪的源缓冲别名；GPU fill 和 blit 按完整 NVN 范围与编译器最小类型尺寸生成每次使用独立的补零私有后备，长度向上对齐 256 字节、最多 64 KiB，绑定偏移为零。源偏移和长度须按 4 字节对齐；未知、越界、heap 后备或超限来源明确失败。原生 setter 直接消费准备好的对象，界面矩阵在该副本上由后续 GPU 计算编码器调整。局部界面的无贴图覆盖判断尚无法在不读取潜在 GPU 写入数据的前提下证明，因此明确拒绝；独立 iPhone-family 目标使用全屏界面。所有在途提交的暂存总量限制为 128 MiB、8,192 个缓冲；只有消费栅栏完成后的后备才可再次写入，每次使用仍重新记录复制。生产路径 CPU 记录器验证同步/复制/setter 顺序、完整范围、补零指令、预算、矩阵派发和栅栏复用。准备外层参数槽之前，先结束原渲染通道并完成其中递归的跟手图绘制；CPU 检查抽取完整的生产准备代码，验证嵌套回放不能覆盖外层先于可变 CBUF 绑定的 C1。由已提交 `7563ead` 构建的新诊断产物通过 host-only ordered-constants 实测：128 KiB 自有 VM 的两个未自动追踪别名，经 GPU 写入、全新事件同步与复制、GPU 矩阵调整及原生常量参数消费，连续三个完成提交中的 64 个值、零尾部、16 个矩阵值和周边保护数据全部匹配。两个私有后备合计 768 字节，在声明的 1,536 字节测试预算内复用四次；14,363 个安装文件保持一致，进程已停止。该结果限定于自有别名/复制/消费拓扑，真实 Guest 池和完整渲染资源上限仍需验证。该案例未观察源别名的实际 deallocator 执行；后备所有者由两个真实 deallocator block 持有。构建器和游戏检查尚未启用该配置。

模拟器深度默认纹理现采用私有、自动追踪的 Depth32Float 后备，以及 shader-read/render-target 用途。准备阶段先结束前一通道和跟手图回放，再在消费编码器创建前，为每个数组切片或立方体面记录显式清除与保存通道。有界缓存最多持有四类纹理，每个新提交重新记录清除；命令缓冲仅被弱引用，准备失败或离开对应命令上下文后不会提供可用条目。CPU 检查覆盖描述符、所有清除/end 配对、分配和编码失败、错误类型/存储/形状、提交序号复用及命令释放。由已提交 `4a252ea` 构建的新 ARM64/platform7 诊断产物通过 host-only private-depth 实测：同一缓存/辅助函数及原生纹理 setter 在两个完成提交中产生预期的 0.625 种子值和清零值。2D、数组及立方体六个面的采样和无采样器读取共 32 个值全部匹配，输出尾部保护数据不变，三个纹理对象得到复用。实际纹理为私有、自动追踪的 Depth32Float，具有 shader-read/render-target 用途；原生参数编码长度与对齐分别为 32、8 字节。限时运行前后全部 14,363 个安装文件一致，应用无崩溃并已停止，自有 GPU 预约已释放。立方体数组目前仅有描述符/清除编排的 CPU 检查。模拟器深度不使用 CPU replaceRegion，MSAA、可写及缓冲深度默认纹理明确失败。该源码尚未启用构建配置或游戏检查；BC/格式、完整资源上限、配置/PSO/预热及真实渲染和世界资格仍待完成。

模拟器参数和资源解析现会在渲染或计算消费编码器创建前完成。每次使用都创建与函数反射长度/对齐一致的新原生编码器、独立且不再改写的参数块，并强引用所需资源与采样器；共享的反射编码器不接收绑定。完成命令对应的退役所有者在发布栅栏之前丢弃这些引用，自身不强持有命令缓冲。实际 arena 后备全局限制为 64 MiB，每个提交另限制 64 MiB 编码字节和 8,192 个参数包。CPU 记录器覆盖先封存后绑定、顶点/片元/计算声明、完整范围、预算、独立参数块、命令弱引用及模拟栅栏发布前的引用退役。由已提交 `43db65c` 构建的新 ARM64/platform7 诊断产物通过 host-only prepared-arguments 实测：消费方创建前先准备两组独立的纹理/采样器参数，丢弃生产方引用后，在完成提交中核对的 128 个输出值及 64 个尾部保护值全部匹配。实际原生编码长度/对齐为 24/8 字节，两组共 48 字节，完成所有者成功退役。前后全部 14,363 个安装文件一致，进程无崩溃并已停止，GPU 预约已释放。该案例没有观察实际对象的 deallocator，也不覆盖生产绘制/派发执行。所有权结果的范围保持不变；BC 传输组件的独立源码与检查状态如下。

显式模拟器 BC 传输路径现会在编码前检查完整且有界的源和目标区域。先结束前面的消费编码器，在主命令流记录新的生产方事件，再等待独立的完成事件；生产方事件到达后才分配暂存区。读取和上传分别使用独立队列、显式拥有资源的不保留引用命令缓冲：线性块通过 GPU 读回，打包纹理通过原有 GPU 解排布，得到自有字节后才由 CPU 解码，并填入有界、清零填充的上传缓冲。解压后的 sRGB 格式使用原始字节 blit，不要求 shader-write 用途。读回完成后丢弃源引用，成功上传后先丢弃暂存和目标引用，再发布完成事件；生产路径限制 256 MiB 输入/上传暂存和 4,096 个待完成请求。接受后的错误明确终止，不会把失败内容标记为成功。

CPU 记录器通过同一个尚未提交的主命令中的两个请求、接受后源修改、源生命周期、禁止读取 source.contents、延后分配、预算、完整范围、打包多级/3D/数组/立方体编排，以及读取/上传失败终止检查。32 组独立固定端点覆盖全部 16 种 NVN BC 格式，包含有符号/sRGB、带填充行距、7x5 不满块边缘、保护数据和 RGB BC1 的 alpha 重映射。有符号 BC6H 端点暴露了上游 bcdec 的有符号左移未定义行为；有界无符号符号扩展已通过独立算术判据，覆盖 1–16 位宽全部 131,070 个值及 96 个极值输入。此行为有定义的算术修正也影响真机 CPU 解压路径；真机后端选择和上传编排不变。恢复原运算的负对照仍会被检查器拒绝。

host-only `bc-transfers` 目前仅完成源码和 CPU 检查，尚无构建产物或 GPU 运行结果。案例定义了 16 种格式各两个由 GPU 写入、经独立不自动追踪别名读取的请求，共 1,120 个预期像素，再检查两个 mip 的 7x5x3 打包 GPU 解排布，共 111 个像素；核对原始解码字节、填充/保护数据、延后暂存分配及完成后的暂存退役。这尚未覆盖完整 BC 语义：压缩原字节影子存储、T2B/ReadTexels、格式/视图重解释和 ASTC 到 BC 桥接均明确失败，现有打包纹理缓存对 GPU 写入的失效处理仍未证明。完整格式/复制语义、最大资源和原生布局、配置/PSO/预热整合及真实渲染/世界资格仍为启用前提；构建器配置选择与游戏启动检查不变。

源码配置元数据现由 `profile_metadata.py` 独立生产和重放验证：明确核对原始与派生配置、完整映射及阶段，真实重新生成并比较 C1，按原始顺序保留支持的 S/R/C 行体。`pso_toolchain.py` 冻结实际生产 C/头文件，以明确的编译器、SDK 依赖和 ARM64 主机/模拟器布局检查驱动共用原生编解码器；二进制历史身份与可重放的源码/布局关系分开记录，不声称链接产物逐字节重现。当前 6,927 个映射键和 392 条种子得到 341 条支持记录（181 S、12 C、148 R）；合并、特化、BF 及明确的空 C 逐行记录排除原因，不改变其描述。输出精确四个文件，描述文件原子发布，绑定来源、工具、真实 C1 时间戳、输出身份、决策和计数。生产与验证共用最终输入准入，在最后一次完整重放后重新核对原始/派生文件及输入/工具/原生闭包，再检查精确输出集合和哈希，才发布描述文件或返回验证成功；阶段依赖限定于 `stage_of` 的精确函数体与标签。Python 3.10 以上的原生夹具及漂移负例通过；此结果仅为源码/CPU 证明，构建暂存、预热、缓存隔离、Metal 参数/PSO 和游戏世界仍需整合及运行验证。

## 1. 对象

| NVN 对象 | Metal 实现 | 要点 |
|---|---|---|
| Device | `MTLDevice`（要求统一内存） | `nvnDeviceGetInteger` 返回的设备属性仍按 Tegra X1 的值给游戏（`hle_nvn.c` 的 `g_devinfo`） |
| MemoryPool | 游戏内存上的 `newBufferWithBytesNoCopy` | 苹果芯片的页是 16 KiB，池不保证按它对齐：起点向下、终点向上取整到页边界再建缓冲，相邻池的缓冲允许重叠（`mtl_pool_add()`；做法由 `metal/probe/p_nocopy.m` 验证） |
| 缓冲地址（`NVNbufferAddress`） | （`MTLBuffer`, 偏移） | 按池的区间表反查 |
| Texture | `MTLTexture` | 游戏打包贴图是块线性排布，上传时解排布；格式映射与解排布在 `tex/`。池内存被游戏改写后重新上传，靠 `nvn/nvn_dirty.c` 的写保护脏页跟踪发现。`ReadTexels`：打包贴图直接从池内存解排布读，GPU 写出的贴图从 `MTLTexture` 读回 |
| TextureView | `newTextureViewWithPixelFormat:textureType:levels:slices:` | — |
| Sampler | `MTLSamplerState` | 边框色 Metal 只有三种预设（透明黑、不透明黑、不透明白），按 NVN 给的边框色就近取 |
| TexturePool / SamplerPool | 宿主侧的表：描述符号 → 贴图 / 采样器 | 分离贴图句柄的值就是描述符号 |
| Program | 每个阶段一个 `MTLFunction` | 以着色器控制段的哈希为键，从离线翻译好的 `<键>_b.metallib` 加载；运行时不翻译。翻译链见 README |
| 状态对象（Blend / Color / ChannelMask / Multisample / Polygon / DepthStencil / VertexAttrib / VertexStream） | 渲染管线描述符的字段 + `MTLDepthStencilState` + 编码器状态 | 游戏按值拷贝这些小结构，宿主侧用位域就地打包。渲染管线、深度模板状态按状态哈希缓存 |
| CommandBuffer | 录在游戏命令内存里的记录流 | 提交时回放 |
| Queue | Metal 命令队列 | `SubmitCommands` = 回放并提交 |
| Sync | 提交的栅栏值 | `FenceSync` 记下最近一次提交的栅栏值；`SyncWait` 只在 GPU 真正完成到该值之后放行（`MTLSharedEvent` 的已完成值）。没围栏过的同步对象等待直接返回超时 |
| Event | 游戏内存里的一个 32 位值 | 写值在 GPU 完成之后发生 |
| Window | 游戏自己的交换链贴图 ↔ `CAMetalLayer` | `AcquireTexture` 返回交换链贴图的下标，垂直同步的等待发生在这里；`QueuePresentTexture` 只把出图排进队列立即返回，由出图线程把该贴图按 `WindowSetCrop` 给的裁切区画到 drawable 上 |

## 2. 命令

| NVN 命令 | Metal | 说明 |
|---|---|---|
| SetRenderTargets | 结束当前渲染编码器，开新的渲染通道 | 通道里第一条命令之前的清除并进附件的读入动作（load = Clear） |
| ClearColor / ClearDepthStencil | 同上 | 通道中途的清除、带部分掩码或部分剪裁的清色没有实现，遇到报红 |
| ClearTexture / ClearTextureui | 单独清一张贴图 | 部分形态没有实现，遇到报红 |
| BindProgram 与各状态 Bind* | 记进当前状态，下一次绘制前按需取管线 | — |
| BindUniformBuffer(s) / BindStorageBuffer(s) / BindSeparateTextures / BindSeparateSamplers / BindImages | 按着色器的反射 json 填参数缓冲（argument buffer） | 槽号与着色器里常量段的对应见 README「着色器翻译链」 |
| BindVertexBuffers | 顶点缓冲 = （`MTLBuffer`, 偏移） | — |
| SetViewports / SetScissor / SetDepthRange / Stencil* / SetBlendColor / SetPolygonOffsetClamp | 编码器上对应的设置 | — |
| DrawArrays / DrawElementsInstanced | 绘制 / 带索引绘制 | Metal 没有四边形图元：不带索引的四边形用共享的索引 0,1,2,0,2,3 画成两个三角形；带索引的四边形、8 位索引没有实现，遇到报红 |
| DispatchCompute | 计算编码器，线程组大小取反射 json | 主程序内嵌的 4 个计算着色器用 `nvn/nvn_builtin.h` 里手写的版本 |
| CopyBufferToBuffer / UpdateUniformBuffer | 命令流里按序插入的缓冲拷贝 | `UpdateUniformBuffer` 的数据在录制时就拷进命令内存，因为 NVN 允许调用方录完后改原数据 |
| CopyBufferToTexture / CopyTextureToBuffer / CopyTextureToTexture | 贴图拷贝 | 贴图到贴图的部分形态没有实现，遇到报红 |
| ReportCounter / ResetCounter | 计数器的值在 GPU 完成之后写回 | 「通过采样数」这一类用 Metal 的可见性结果缓冲实现 |
| SignalEvent | 事件写值，GPU 完成之后发生 | — |
| SetTexturePool / SetSamplerPool | 录进命令流，记下当前用的描述符池 | — |

下面这些是空实现（`hle_nvn.c` 的 `g_nops`），调用不报红也不产生效果：

`SetPatchSize`、`MultiDrawArraysIndirectCount`、`MultiDrawElementsIndirectCount`、`DispatchComputeIndirect`、`SetDepthBounds`、`DownsampleTextureView`、`WaitSync`、`SetShaderScratchMemory`、`PushDebugGroupDynamic`、`PopDebugGroup`、`InsertDebugMarkerDynamic`、`WaitEvent`，以及 `nvnWindowFinalize`。

## 3. 着色器绑定

Switch 的着色器通过驱动维护的几个常量段拿到资源，图形层在回放时把同样的内容填进 Metal 的参数缓冲。反射 json 里每个绑定带一个种类（`nvn/nvn_refl.h` 的 `NVN_RB_*`）：

| 种类 | 含义 |
|---|---|
| `CBUF` | uniform 缓冲槽 r |
| `TEX` / `SAMP` / `SAMPT` | 分离贴图槽、分离采样器槽；`SAMPT` 表示采样器取自贴图槽的合并句柄 |
| `IMG` | 可写贴图（图像槽） |
| `TBUF` | 类型化缓冲（缓冲贴图） |
| `SBUFP` | 存储缓冲槽的设备指针 |
| `UBOP` | 计算阶段 uniform 槽的设备指针 |
| `C1` | 着色器自带的常数段 |
| `DRV0` / `DRV2` | 驱动常量段 c[0]（存储缓冲地址表）与 c[2]（贴图、采样器句柄表），由回放层按当前绑定现填 |
| `SUPPORT` | 翻译器自己用的辅助常量 |

没有绑定的贴图槽给一张哑贴图，类型与像素类别取自反射。

## 4. 加一个还没实现的函数

1. 在 `nvn/hle_nvn.c` 里用 `NVN(名字, 返回类型, 参数…)` 宏写实现。宏会按 `nvn/nvn_protos.h` 做签名检查，并把实现登记进槽表；名字不在 `nvn/names.txt` 里启动即中止。
2. 如果是命令：在 `nvn/nvn_obj.h` 里加记录格式，录制写在 `hle_nvn.c`，回放写在 `nvn/nvn_mtl.m`。
3. 在 `tests/` 里加测试，`make -C dm/gfx/tests run`。

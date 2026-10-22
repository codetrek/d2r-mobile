# 源码配置选择、验证与装包

构建器必须显式选择 `--shader-mode canonical` 或 `--shader-mode derived-profile`。两种模式都生成独立的 ARM64/platform7 模拟器应用；配置选择只影响已声明的源码资源和身份常量，`DM_NVN_SIMULATOR` 尚未启用，游戏启动检查保持原状。

## 原始源码模式

`canonical` 使用原有 `--shader-cache`、`--shader-manifest` 和 `--shader-metadata`。按当前生成器核对原始基础/BF 源码覆盖，并保留对应原始元数据。此模式不接受派生描述文件或验证解释器参数，也不会携带旧的派生配置描述文件。

## 派生源码模式

`derived-profile` 保留上述三个参数作为明确的原始输入，并额外要求配套参数：

| 参数 | 输入 |
|---|---|
| `--shader-profile` | 含真实 `profile.json`、证明及基础源码目录的完整派生配置 |
| `--profile-metadata` | 已生产的精确四文件元数据目录 |
| `--metadata-descriptor-sha256` | 调用者先前保存并信任的元数据描述文件 SHA-256 |
| `--validation-python` | 与元数据来源记录完全相同的 Python 可执行文件；当前私有配置记录 Python 3.13 |

缺少配对、错误描述身份、链、键、阶段、ABI、文件集合、解释器或源数据漂移均明确失败。不要先读取待检文件并自动信任新算出的哈希。

完整 `dm/` 源码和所有输入先建立有界只读快照。`profile_inputs.py` 从该冻结源码逐字节复制必要的 Python/C/头文件及阶段函数来源到本次构建拥有的独立验证目录。验证器从这份副本执行；其自身仓库目录下的 `.tmp` 保存选定元数据副本、C1、原生 CPU 编译器工作及回执。原始冻结源码与主要输入保持不变，现有元数据 API 的路径保护正常生效；没有改写校验器的仓库根、来源身份或路径限制。

验证使用实际 `profile_metadata.validate_metadata` 及完整 canonical replay，重新编译自有原生工具并对照真实 ARM64 布局、元数据/原始/派生来源。执行前后比较整个主要冻结源码、隔离工具闭包、输入、描述文件和解释器身份。复制目录中多出的工具文件也会失败。验证结果明确标为源码/CPU、未经过 Metal 编译或执行，不能证明管线或游戏可用。

通过验证后，只按准入结果暂存全部基础 `_b.json` 和保存真实 MSL 源码的 `_b.metallib`，不生成、重命名或复制 BF。映射表、真实 C1、过滤后的有序 PSO 按元数据描述文件绑定的字节暂存。包内另携带 `dm/simulator-shader-profile.json` 和 `dm/simulator-metadata-profile.json`；前者是完整源输入的来源描述，包内暂存的是经核对的基础 JSON/源码库子集，完整原始/派生输入身份保存在构建清单中。

生成的 `profile.h` 绑定独立链、源码配置、元数据 SHA-256/逻辑身份，并写明 `DM_SIMULATOR_PROFILE_ACTIVATED=0`。生成文件、两个描述文件和资源从源快照到暂存、链接后复制、普通签名后的最终整包都沿用同一份预声明身份。`d2r.ios-simulator-build.v3` 清单记录模式、CPU 准入、隔离工具/解释器、输入与资源、生成常量及最终文件清单，状态保持 `built_unexecuted`、`renderer_profile_activated=false`。

## 命令与检查

沿用原构建的模块、donor App、三个生成表与输出参数。原始模式额外明确：

```sh
python3.13 dm/ios/tools/simulator/build.py --shader-mode canonical \
  --modules '<模块目录>' --app-resources '<匹配的 App.app>' --tables '<生成表目录>' \
  --shader-cache '<原始 b-链目录>' --shader-manifest '<原始资格清单.json>' \
  --shader-metadata '<原始三文件元数据目录>' --out "$PWD/.tmp/canonical-build"
```

派生模式增加四个配套参数：

```sh
python3.13 dm/ios/tools/simulator/build.py --shader-mode derived-profile \
  --modules '<模块目录>' --app-resources '<匹配的 App.app>' --tables '<生成表目录>' \
  --shader-cache '<原始 b-链目录>' --shader-manifest '<原始资格清单.json>' \
  --shader-metadata '<原始三文件元数据目录>' \
  --shader-profile '<完整派生配置目录>' --profile-metadata '<配套四文件元数据目录>' \
  --metadata-descriptor-sha256 '<事先保存的描述身份>' --validation-python '<记录的 Python 3.13>' \
  --out "$PWD/.tmp/derived-build"
```

纯 CPU 检查不需要游戏或模拟器：

```sh
python3.13 dm/ios/tests/test_simulator.py
make -C dm/ios/tests profile-staging PYTHON=python3.13
```

检查包含实际隔离 CPU 验证器、冻结源不变、解释器/ABI/闭包负例、基础成对覆盖、BF/链拒绝、复制末尾损坏/多文件、元数据描述配对与身份，以及链接后资源复制/整包描述文件篡改。实际 6,927 键及元数据03另进行冻结输入准入和构建资源准备证明；准备证明不是应用编译、GPU、游戏或预热回执。

源码预热的共享编译契约、用户 PSO 缓存隔离、全部 Metal 原生参数/PSO、真实渲染和游戏世界仍需后续整合与独立运行证明。服务端联机逻辑的部署不依赖这份客户端模拟器界面或图形验证工具。

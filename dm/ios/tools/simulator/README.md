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

构建前先复制实际源码与工具输入，包括当前分支的已跟踪文件和未跟踪工具源码，记录捕获时的 Git revision、差异摘要和逐文件身份。生成工具与编译器读取这份独立源码快照。模块、表、donor 资源、着色器缓存及清单和元数据也先形成独立只读快照。快照拒绝输入符号链接，并限制文件数量、单文件大小和总大小。

工具逐字节核对 donor 的四份 `main/sdk.fixups/gates.tsv` 与选定模块，并从 donor Guest 的六个模块节核对 main/sdk 字节及对齐填充。`PRODUCT` 相同不足以通过。运行表统一从选定模块快照暂存；`shader_map.tsv`、`pso_manifest.tsv` 和 `c1_full.tsv` 明确取自选定着色器元数据快照，覆盖 donor 的对应版本。这些关系与覆盖后的期望身份进入构建清单。

每份派生资源复制后按输入快照中预先声明的哈希核对，不把复制后的内容重新当成可信基准。生成的 native-art C 源码和构建配置绑定生成器所产生的期望字节摘要；复制的表头绑定原输入快照。Gen 中的源文件链接只允许指向这份源码快照，并绑定确切目标。

Xcode 只负责代码和自有 AppIcon；派生界面资源、运行表及源码着色器在链接完成后由工具复制进最终应用，保持字节原样，再正常签名。签名后重新核对最终资源的路径集合和哈希、Guest 的六个模块节和四份运行表、framework 元数据，并记录最终整包的逐文件清单。缺失、多出、损坏或错误来源的资源都会阻止成功清单发布。

发布 `d2r.ios-simulator-build.v2` 清单前，还会再次复核完整源码和输入快照、原输入、暂存文件集、工程描述与工具二进制。清单的成功状态是 `built_unexecuted`。静态关系检查不认证 Apple 签名；Apple SDK、系统框架和操作系统仍是已安装的外部依赖，这不是完整系统环境的归档。

构建不会启动游戏或操作手机。安装和运行检查使用仓库 `.tmp` 下独立的 CoreSimulator device set；具体设备、环境、时限和清理记录留在私有回执。原始手机存档和用户存档保持原样。

## 已验证范围

2026-10-21 的历史私人 build02 构建成功，应用及 Guest 均为 ARM64/platform7；6,927 份反射和 7,212 份源码库（含 285 个 BF 变体）完成静态核对。独立只读复核的 20 项产物检查通过，模拟器上的线程存储 508–511 槽检查通过。历史构建的 Xcode 资源阶段改写过 14 份 PNG；新工具采用上述链接后原样装包流程。旧回执保持原本的源码、产物与验证范围，不改写为新工具的结果。

当前 23 项合成测试覆盖模块与四份运行表关系、donor/模块字节变化、Mach-O 边界、设备与模拟器平台、着色器及 BF 集合、独立快照、复制期间和之后的变动、路径与大小限制、源链接目标替换，以及复制损坏和最终资源缺失、多出或损坏。真实私人 donor 的模块和四份表通过关系检查，既有源码着色器缓存也通过当前分支的完整 BF 核对。

新 v2 构建候选及运行检查尚待执行。实际着色器编译、画面、进局、正常保存退出和两个客户端共享同一权威世界，分别需要自己的运行回执；构建或线程检查通过不表示联机可用。

## 合成测试

```sh
python3 dm/ios/tests/test_simulator.py
```

测试不需要原游戏或模拟器，临时数据留在仓库 `.tmp/simulator-tests`。源码快照测试只读取 Git 索引和当前文件，不创建提交。完整 iOS 测试入口也运行这些检查；原有需要私人夹具或生成技能资源的测试继续遵守各自的输入条件。

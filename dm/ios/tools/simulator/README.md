# ARM64 iOS 模拟器构建

本 fork 在 `with-server` 开发模拟器与联机适配，`main` 跟进上游。本工具构建独立的 `DmIOSSimulator` 应用；默认的真机平台和构建入口保持原有语义。

## 输入与构建

需要 Apple Silicon、Xcode 的 iPhoneSimulator SDK、XcodeGen 和 Python3.12 或以上。输入必须来自同一套自有游戏与对应源码版本：main/sdk 改写映像及四份 fixup/gate 表、已生成的三个宿主数据表、私人 App 的派生界面资源，以及已核对的源码着色器缓存、清单和配套元数据。原游戏、资源和生成应用不进入 Git。

从仓库根目录执行，输出必须是仓库 `.tmp` 内尚不存在的目录：

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

工具通过每次构建的 `DEVELOPER_DIR` 选择 Xcode，不改变系统选择。生成独立 target、全新的 ARM64 platform7 Guest.framework 和 iPhoneSimulator plist，使用本地签名；不把真机 framework 改名后复用。模拟器显式启用 `DM_NVN_M3=1` 和单独的源码着色器链。缓存中名为 `.metallib` 的条目在本路径里是 MSL 源码，实际 Metal 编译及覆盖范围需要运行检查。

构建不会启动游戏或操作手机。安装和运行检查使用仓库 `.tmp` 下独立的 CoreSimulator device set，具体设备身份和启动记录留在私有回执中。

## 已验证范围与待修复项

2026-10-21 的私人 build02 构建成功，应用及 Guest 均为 ARM64/platform7；6,927 份反射和 7,212 份源码库（含 285 个 BF 变体）完成静态核对。独立只读复核的 20 项产物检查通过，模拟器上的线程本地存储 508–511 槽检查通过。十项合成测试覆盖默认真机平台、模拟器平台、空集合、错误链和缺失或损坏的 BF 数据。

当前构建工具还有两项来源校验需要修复：构建前冻结并绑定完整的实际源码和暂存资源，以及强制核对 donor 的运行 fixup/gate 表与新生成 framework 的模块输入一致。历史 build02 的实际文件匹配检查已通过；这些结果不等于构建工具已具备完整的输入冻结保证。修复会单独提交并生成新的候选与回执。

进入世界、实际画面和着色器覆盖、保存退出、两个客户端共享同一权威世界尚未通过验证。模拟器应用构建成功不表示联机可用。

## 合成测试

```sh
python3 dm/ios/tests/test_simulator.py
```

测试不需要原游戏或模拟器，临时数据留在仓库 `.tmp/simulator-tests`。完整 iOS 测试入口也会运行这些检查；原有需要私人夹具或生成技能资源的测试继续遵守各自的输入条件。

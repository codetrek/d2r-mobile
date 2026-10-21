# ARM64 iOS 模拟器构建

本 fork 在 `with-server` 开发模拟器与联机适配，`main` 跟进上游。本工具构建独立的 `DmIOSSimulator` 应用；默认真机平台和构建入口保持原有语义。

## 输入与构建

需要 Apple Silicon、Xcode 的 iPhoneSimulator SDK、XcodeGen 和 Python 3.12 或以上。输入来自同一套自有游戏和对应源码版本：main/sdk 改写映像、四份 fixup/gate 表、三个已生成的宿主数据表、私人 App 的派生界面资源，以及有完整资格清单和配套元数据的源码着色器缓存。原游戏、资源和生成应用不进入 Git。

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

工具按每次构建的 `DEVELOPER_DIR` 选择 Xcode，生成独立 target、全新的 ARM64 platform7 Guest.framework 和 iPhoneSimulator plist，使用普通本地签名。模拟器显式启用 `DM_NVN_M3=1` 和独立源码着色器链。此路径里名为 `.metallib` 的缓存文件保存 MSL 源码；真正的 Metal 编译仍需在模拟器中验证。

构建前会逐字节核对 donor 的 `main.fixups.tsv`、`main.gates.tsv`、`sdk.fixups.tsv`、`sdk.gates.tsv` 与选定模块输入，并从 donor Guest 的六个模块节核对 main/sdk 字节及对齐填充。`PRODUCT` 相同不足以通过。运行表统一从选定模块输入暂存，清单记录模块、表与 donor Guest 的 SHA-256。这项静态关系检查不认证 Apple 签名。

构建不会启动游戏或操作手机。安装和运行检查使用仓库 `.tmp` 下独立的 CoreSimulator device set，具体设备身份和启动记录留在私有回执中。

## 已验证范围与待完成项

2026-10-21 的历史私人 build02 构建成功，应用及 Guest 均为 ARM64/platform7；6,927 份反射和 7,212 份源码库（含 285 个 BF 变体）完成静态核对。独立只读复核的 20 项产物检查通过，模拟器上的线程存储 508–511 槽检查通过。这些历史回执保留原本的源码和产物身份。

当前 13 项合成测试已覆盖 donor 与选定模块匹配、四份运行表分别不匹配、donor/选定模块字节变化和容器边界，以及设备默认平台、模拟器平台、空集合、错误链、缺失或损坏的 BF 数据。真实私人 donor 的两份模块与四份表也通过了新增关系检查。

完整实际源码、工具与暂存资源在整个构建区间内的冻结和身份复核仍待补齐。完成后会生成新候选，重新验证其线程、着色器、实际画面、进局及正常保存退出。历史 build02 的成功不表示这些保证已由旧构建工具提供。

两个客户端共享同一权威世界尚未通过验证；模拟器构建与单独启动不表示联机可用。

## 合成测试

```sh
python3 dm/ios/tests/test_simulator.py
```

测试不需要原游戏或模拟器，临时数据留在仓库 `.tmp/simulator-tests`。完整 iOS 测试入口也运行这些检查；原有需要私人夹具或生成技能资源的测试继续遵守各自的输入条件。

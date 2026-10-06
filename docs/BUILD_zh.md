# 构建说明

版本：1.7.5。目标平台：Windows x64。

## 工具与依赖

- 含标准库 zlib 的完整 Python 3.10 或以上；本次发行使用 Python 3.11.9、zlib 1.3.1，不需要 pip 包。
- LLVM-MinGW x86_64 UCRT 工具链，本次发行使用 `llvm-mingw-20260616-ucrt-x86_64`，Clang 22.1.8。
- REFramework 插件 API 头文件及许可证已随源码提供，固定提交为 `a0e9010fb0449dc9d824b5978ee759eeaf50f7c6`。
- 编译要求支持 C++17 和 Windows x64 静态链接；不需要 Visual Studio、游戏文件、BoneSystem.dll 或独立 Lua 编译器。

使用相同工具链、Python/zlib 和未修改的源码，可重建相同发布文件；其他编译器版本不保证 DLL 字节完全相同，
其他压缩库版本也不保证 ZIP 字节完全相同。
构建脚本不下载依赖、不安装插件、不连接正在运行的游戏。运行前置与实际功能请看根目录 README。

## 构建命令

在源码根目录执行，替换 Python 和工具链路径为本机位置：

```powershell
python -B tools/build.py --compiler "C:/tools/llvm-mingw/bin/clang++.exe"
```

工具会按照 manifest 顺序合并 Lua，生成正式脚本，再编译两个 DLL 并生成安装包。
发布源码与含注释源码使用相同命令；含注释源码只是维护形式不同，不增加运行功能。

## 输出位置

| 路径 | 内容 |
| --- | --- |
| `reframework/autorun/BSNPC.lua` | 由源码单元生成的正式脚本 |
| `reframework/autorun/BSFNStockBridge/bootstrap.lua` | 原版 BoneSystem 私有状态引导 |
| `out/release/BSFNStockBridge.dll` | 启动适配器 |
| `out/release/BSFNForefoot.dll` | 按需调用的龙人原生辅助器 |
| `out/release/build.json` | 本次构建产物的版本与摘要，不进入安装包 |
| `dist/BSFN_v1.7.5/` | 完整发布文件夹，不再套一层压缩包 |
| `dist/BSFN_v1.7.5/BSFN_v1.7.5.zip` | 可交给 Mod 管理器安装的 ZIP |
| `dist/BSFN_v1.7.5/LICENSE`、`THIRD_PARTY_NOTICES.md`、`docs/licenses/` | 与安装 ZIP 一起分发的许可证及第三方声明 |

修改 `src/lua` 或 `src/bridge/bootstrap.lua` 后重新执行构建，不单独修改生成的 autorun 文件。
`assets/natives` 是必需运行资源，会原样进入安装包。安装 ZIP 仅含 `reframework/`、必要的
`natives/`、`modinfo.ini` 和 `README.md`。许可证放在发布文件夹中，与安装 ZIP 同级，
不安装到游戏目录；各许可证的相对路径和内容保持不变。

发布或转发时必须提供完整的 `dist/BSFN_v1.7.5/` 文件夹，不单独分发里面的安装 ZIP，
也不把许可证作为另一个可选下载。构建不生成外层压缩包。两种源码包仍保留各自完整许可证。

根目录 README 同时用于安装包，修改后重新构建即可同步。输出目录可删除后重新生成，
不要把 `out` 或 `dist` 当作源码的一部分提交。

`.gitattributes` 禁止 Git 自动转换换行，保留用户 README、依赖、许可证与资源的原始字节。
请保留此文件；它保证经过提交和克隆后仍能按相同环境复现发布包，不改变运行逻辑。

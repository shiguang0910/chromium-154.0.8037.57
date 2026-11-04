# Chromium 154.0.8037.57

完整可编译树（含 `depot_tools`、构建依赖同步产物），版本锁定为标签 **154.0.8037.57**。

分片下载见 Releases：https://github.com/shiguang0910/chromium-154.0.8037.57/releases/tag/v154.0.8037.57

Release 资源中另附 **`checkout-chromium-tag.sh`**，可日后按任意标签重新检出完整可编译源码。

## 下载与拼包

Release 中提供 15 个分片（`part01`–`part15`，每片约 1.9GB，最后一片较小）、`README.txt` / 重组说明，以及检出脚本。

```bash
# 下载全部 part 后
cat chromium-154.0.8037.57.tar.part* > chromium-154.0.8037.57.tar
sha256sum chromium-154.0.8037.57.tar
# 应为：
# d08d3f25e24457d5ccec794aabddd0327b1e7b0c406c074b52b76e2cfa12026f

tar -xf chromium-154.0.8037.57.tar
```

解压后目录结构：

- `chromium/src/` — 源码树（含 `.gclient` 等同级元数据在 `chromium/`）
- `depot_tools/` — 构建工具
- `checkout-chromium-tag.sh` — 指定标签完整可编译检出脚本

> 这棵树为浅同步（无完整 git 历史），版本已锁定，一般足够编译。不要随意执行会拉全量历史的 `git fetch`。

## 环境

```bash
export PATH="$PWD/depot_tools:$PATH"
# 建议写入 ~/.bashrc
```

磁盘建议：源码之外再留 **80GB+** 空闲给 `out/` 产物。

## 安装宿主机依赖

```bash
cd chromium/src
sudo ./build/install-build-deps.sh
```

银河麒麟等发行版若脚本无法识别，请根据报错补齐依赖，或对照 Debian/Ubuntu 依赖安装后再继续。

## 性能向编译（尽量接近官方 Chrome）

不能保证与官网 Chrome 安装包在运行性能上 **完全一致**（品牌化、部分媒体/闭源配置、构建环境差异等），但在同一版本 `154.0.8037.57` 上，使用下方参数可使一般浏览、JS、渲染性能 **非常接近** 官方 Linux Chrome。若树内已包含匹配的 Clang 与 Linux PGO，请保留 `chrome_pgo_phase=2`。

```bash
export PATH="$PWD/depot_tools:$PATH"   # 在含 chromium/ 与 depot_tools/ 的目录执行
cd chromium/src

gn gen out/Official --args='
  is_debug=false
  is_component_build=false
  is_official_build=true
  chrome_pgo_phase=2
  symbol_level=0
  blink_symbol_level=0
  v8_symbol_level=0
  dcheck_always_on=false
'

autoninja -C out/Official chrome
```

产物：`out/Official/chrome`

### 参数说明

| 参数 | 作用 |
|------|------|
| `is_official_build=true` | 启用官方同款优化（Linux 上通常一并启用 ThinLTO 等） |
| `chrome_pgo_phase=2` | 使用树内已下载的 PGO profile；缺少此项会明显慢于官方 |
| `is_component_build=false` | 组件构建运行更慢，官方包不是这种形态 |
| `is_debug=false` / `dcheck_always_on=false` | 去掉调试开销 |
| `symbol_level=0` 等 | 主要减小体积、加快链接，对运行速度影响很小 |

**不要使用：** `is_debug=true`、`is_component_build=true`、`chrome_pgo_phase=0`、asan/tsan 等 sanitizer。

### 与官方仍可能存在的差异

- 官方为 Google Chrome 品牌；本仓库为 Chromium（同步、部分 Google 服务、专有编解码等不同）。
- 媒体/DRM 等若要更接近官方，需额外配置（及许可），不在本 README 默认范围内。
- 请勿随意添加激进的 `-march=native` 等，除非你明确接受兼容性风险。

### 自测建议

与同版本官网 Chrome 在同一台机器上对比（关扩展、相近环境）：

1. [Speedometer 3](https://browserbench.org/Speedometer3.0/)
2. [MotionMark](https://browserbench.org/MotionMark/)
3. 冷启动与重站点首屏

若分数明显偏低：检查 `out/Official/args.gn` 是否包含上表项，并确认 `chrome/build/pgo_profiles/` 与 `third_party/llvm-build` 仍在（若本树同步时已拉取）。

## 日后按标签重新检出

```bash
./checkout-chromium-tag.sh 154.0.8037.57 ~/src/chromium-154
# 完整历史（体积更大）：FULL_HISTORY=1 ./checkout-chromium-tag.sh <tag> [outdir]
```

## 其他说明

- 勿删除 `third_party/llvm-build` 与 `chrome/build/pgo_profiles/`（若存在），否则需重新下载工具链/PGO。
- 改 `args` 后重新 `gn gen`（或 `gn args out/Official`）再编译。
- 仅调试、不追求性能时，可去掉 `is_official_build` 与 `chrome_pgo_phase`，编译更快但运行会慢不少。

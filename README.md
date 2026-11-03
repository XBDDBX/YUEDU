# 清阅 · iOS 本地阅读器（含自定义书源）

一个从零写的 iOS 阅读 App，功能对标市面上的本地小说 / 听书阅读器，**核心是书源系统**：
导入 legado（阅读 3.0）格式的书源 JSON，就能自己搜书、追更、看全网内容。

**没有任何会员、内购、付费墙、广告**——因为这个 App 里根本不存在这套东西，不是破解掉的。

---

## 1.1.0 更新

- **界面回到四栏**：书架 / 找书 / 书源 / 设置，发现页收进「找书」右上角
- **设置页改成卡片式**：配置、朗读、替换净化、目录规则、阅读设置、字体管理、章节预缓存、外观主题、统计、文件管理、备份与同步、缓存管理
- **书源导入重做**：链接 / 剪贴板 / 文件 三入口 → 预览列表逐个勾选 → 标出已存在 → 全选反选 → 批量归组 → 一次导入
- **阅读引擎**：五种翻页（覆盖 / 滑动 / 仿真卷页 / 上下滚动 / 无动画）、双栏排版、首行缩进、字距、章节预缓存
- **替换净化**：正文 / 书名 / 目录三个作用域，正则或纯文本，逐条开关、排序、导入导出，带命中预览

---

## 功能

| 模块 | 说明 |
|---|---|
| 书源系统 | 导入 legado / 阅读 3.0 的 bookSource JSON，支持链接 / 剪贴板 / 文件三种导入方式 |
| 规则引擎 | 支持 `class.xxx` `id.xxx` `tag.xxx` `text.xxx` `children`、`@text/@html/@href/@src`、`||` 兜底、`&&` 合并、`##正则##替换##`、`[n]` 索引、`@json:` + JSONPath |
| 搜索 | 多书源并发搜索，结果去重，失败的源可单独查看原因 |
| 目录 / 正文 | 自动抓目录、抓正文，支持正文分页跟进（下一页规则） |
| 阅读器 | CoreText 分页排版、六种主题、五种翻页动画、双栏、字号 / 行距 / 字距 / 缩进调节、章节定位、进度保存 |
| 听书 | 系统 TTS 朗读、可选音色、语速调节、读完自动翻页续读、朗读高亮 |
| 本地书 | 导入 TXT（自动识别章节标题切章）、EPUB（解析 opf / spine / nav 目录） |
| 净化 | 替换净化 + 目录规则，正文加载时自动执行，支持正则与命中预览 |
| 缓存 | 章节内容本地缓存 + 向后预缓存章节，清理入口在设置里 |

---

## 怎么拿到 IPA（不需要 Mac）

这个仓库带了一条 GitHub Actions 流水线，推上去它自己编译出**未签名 IPA**。

1. 在 GitHub 新建一个仓库（私有公开都行）
2. 把本目录下所有文件传上去（网页上直接拖拽上传即可，注意 `.github` 文件夹也要传）
3. 打开仓库的 **Actions** 标签页 → 左侧 **Build unsigned IPA** → 右侧 **Run workflow**
4. 等 5~10 分钟，跑完后进这次运行记录，页面最下方 **Artifacts** 里下载 `QingYue-unsigned-ipa`
5. 解压得到 `QingYue-unsigned.ipa`

> 每次改完代码 push 上去它会自动重编。

### 装到手机上

未签名 IPA 需要一个签名工具，任选一个：

- **Sideloadly**（Windows / macOS）：手机连电脑 → 拖入 ipa → 填自己的 Apple ID → Start
- **AltStore / SideStore**：手机上装，用 Apple ID 签名
- **TrollStore**（仅限支持的系统版本）：直接安装，不掉签

免费 Apple ID 签的证书 **7 天过期**，到期重签一次即可，书和进度不会丢（存在 App 沙盒里，重签同 bundle id 会保留）。

---

## 书源怎么用

App 里 → **书源** → 三种导入方式任选：

- **从链接导入**：填一个书源 JSON 的直链
- **从剪贴板导入**：把书源 JSON 复制下来再点
- **从文件导入**：选本地 .json 文件

`examples/example-booksource.json` 是一个格式模板，照着填就能写自己的源。

书源规则速查在 App 内的 **设置 → 书源规则说明** 里，也在本仓库 `docs/rule-cheatsheet.md`。

### 规则支持范围（重要）

支持：CSS 选择器体系、`class./id./tag./text.` 前缀、链式 `@` 动作、`||` `&&`、`##正则##`、`[n]` 索引、JSONPath。

**不支持**：`@js:` 内嵌 JavaScript、`{{ }}` JS 模板、XPath（`//` 开头）、`@put/@get` 变量。
遇到这类规则的书源，搜索或正文可能取不到内容——这是引擎边界，不是 bug。

---

## 本地编译（有 Mac 的话）

```bash
brew install xcodegen
xcodegen generate
open AuraRead.xcodeproj
```

选自己的开发者账号签名，真机运行即可。命令行打包：

```bash
xcodebuild -project AuraRead.xcodeproj -scheme AuraRead \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

---

## 已验证 / 未验证

- ✅ 书源规则引擎、网络层、书源调度、数据模型：已通过 Swift 5.9 编译器完整类型检查（零错误零警告）
- ✅ 全部源码：已通过语法解析
- ⚠️ SwiftUI / UIKit 界面层：本机无 macOS SDK，未做编译验证，需要在 CI 或 Xcode 里跑一次
- ⚠️ 未签名 IPA 首次编译建议先看 Actions 日志，若有报错把日志贴出来即可定位

## 技术栈

- SwiftUI，iOS 17+
- CoreText 排版分页
- AVSpeechSynthesizer 朗读
- [SwiftSoup](https://github.com/scinfu/SwiftSoup) HTML 解析
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) EPUB 解包
- XcodeGen 管理工程文件

## 目录结构

```
Sources/
  AuraReadApp.swift        入口 + 根 TabView
  Models/                  Book / Chapter / BookSource / ReaderSettings
  Store/AppStore.swift     持久化与全局状态
  SourceEngine/            规则引擎、网络层、书源调度
  Reader/                  分页、绘制、朗读、阅读页
  Import/                  TXT / EPUB 解析
  Views/                   书架、搜索、详情、书源管理、设置
Resources/                 AppIcon
.github/workflows/         CI：出未签名 ipa
```

## 1.2.0 更新（书源导入 + 朗读引擎）

### 书源导入
- 多格式解析：单对象 / 数组 / `{bookSources:[…]}` / `sources` / `data` / `list` 都能认
- 容错：带注释、带尾逗号、带说明文字、GB18030 编码的文件都能读
- 纯链接列表导入：一行一个订阅地址，自动逐个拉取
- 导入前体检：每个源标出「可用 / 部分 / 不完整」，列出缺哪条规则（目录、正文、搜索）
- 受限写法提示：用到 XPath 的源会标出来（引擎不执行 XPath）
- 筛选、搜索、全选、反选、只选可用、批量归组、自动跳过重复

### 朗读引擎
- 长文本按句切段朗读，段与段自动衔接
- 自定义 TTS 引擎：下一段提前预取，播放不断档
- 支持 GET / POST、自定义请求头、请求体模板
- 支持三种返回：直接音频 / JSON 里的音频地址 / JSON 里的 Base64
- 后台播放 + 锁屏控制台（播放、暂停、上一段、下一段）
- 听书定时停止（15 / 30 / 60 分钟）
- 音调调节、音色试听、进度显示
- 朗读引擎也从文件 / 剪贴板 / 链接导入，带连通测试

# 家庭记账 · iOS 原生版（v0.1 骨架）

PWA 版的「原生重做」。目标只有一个：**自己家两台 iPhone 用得更顺手**，不做上架。

> 重要声明：这些 Swift 文件是在 Windows 上写的，**没有经过 Xcode 编译**。
> 逻辑（解析引擎、同步协议）是从已经跑过 39 条测试的 JS 代码逐行移植的，
> 但 Swift 编译期的问题（类型推断、并发标注、个别 API 签名）必须真机编译一遍。
> 预计第一次编译要修 30–60 分钟，这是正常的，不是方案有问题。

---

## 一、这条路为什么值得走

| | PWA（现在） | 原生 App |
|---|---|---|
| 触发 | 快捷指令 4 个动作，要插变量 | **1 个动作**：截取屏幕 → 记一笔（或手动截屏后点图标，App 自己捞截图） |
| 识别 | tesseract.js 精简模型（1.7MB） | 系统 Vision，准确率高一大截，快 3 倍，不联网 |
| 同步 | 自建 Node 服务 + 邀请码 | 先沿用，v2 可换 CloudKit |
| 数据 | 存在 Safari 存储里，极端情况会被清 | 存本机文件 + 家庭交换站 |
| 迭代 | 改完刷新即生效 | 打包 → 安装，慢一个数量级 |

最后一行的代价是真实的：**如果你经常改规则，PWA 反而更快**。所以建议两套并行一段时间。

关键：**App 和 PWA 用同一个 `/api/sync` 协议、同一个家庭码，可以混着用**。
先装 App 试一周，不满意随时退回网页版，账目不会分裂。

---

## 二、文件清单

```
project.yml              XcodeGen 工程定义（生成 .xcodeproj，不用手写）
.github/workflows/ios.yml  GitHub 上免费 macOS 编译 + 出 ipa
SnapLedger/
  SnapLedgerApp.swift    入口
  Models.swift           数据模型 + JSON 文件存储（替代 localStorage）
  Parser.swift           ★ 解析引擎，从 ocr.js 1:1 移植（约 600 行）
  SyncEngine.swift       ★ 同步客户端，从 sync.js 移植（LWW + 墓碑 + 水位线 + 自愈）
  VisionOCR.swift        Vision 中文识别 + 截屏感知（相册增量检测）
  RecordIntent.swift     App Intents：记一笔 / 从图片记账
  ChatView.swift         聊天流 + 待确认卡片 + 本月汇总
  SettingsView.swift     家庭码、身份、相册权限
  ParserTests.swift      25 条回归用例
```

★ 这两个文件是资产，别重写。PWA 里那 39 条测试覆盖的就是它们。

`ParserTests.swift` 里的期望值不是拍脑袋写的：我把每一条用例都用网页版 `ocr.js` 实跑核对过，
所以只要 Swift 移植没走样，测试就应该全绿；**测试挂了 = 移植出错**，别去改期望值。

根目录的 `check_balance.py` 只用来在 Windows 上粗查括号配平（这里没有 Swift 编译器），
不属于 App，不用加进 Xcode。

---

## 三、免费方案：能走通，但每条都有代价

先说结论：**不花 $99 可以做出能装在自己两台 iPhone 上的 App**，代价是「每 7 天要续一次签名」。
而你要的功能恰好一个都不在苹果的付费能力清单里（见下表），所以限制没伤到我们。

| | 免费 Apple ID | $99/年 |
|---|---|---|
| 装到自己手机 | ✅ 7 天后失效，需续签 | ✅ 一年 |
| 同时装几个 App | 3 个 | 不限 |
| 推送通知 / iCloud / CloudKit / App Groups | ❌ | ✅ |
| TestFlight / App Store | ❌ | ✅ |
| **我们用到的东西**：Vision、相册、App Intents、本地文件、自建 HTTP 同步 | **全部可用** | 同 |

三条路，从省事到折腾：

| 路线 | 一次性成本 | 之后每 7 天 | 适合 |
|---|---|---|---|
| **A. 借一台 Mac** | 半天（借电脑） | 插线点一下 Run | 有 Mac 的朋友 |
| **B. GitHub 编译 + Windows 签名**（本文档主线） | 约 40 分钟配置 | Sideloadly 自动续签（电脑在线即可） | **你现在的处境** |
| **C. SideStore 纯手机续签** | 比 B 多 20 分钟 | 手机自己续，但要常挂本地 VPN | 电脑不常开 |

---

## 四、路线 B：只有 Windows 怎么做

原理：SwiftUI 只能在 macOS 上编译，所以借 GitHub 的 macOS 机器编译，产出**未签名**的 ipa；
回到 Windows 用 Sideloadly + 你的免费 Apple ID 签名装进手机。

### ① 仓库（已建好）

公开仓库：**https://github.com/qige039-arch/snap-ledger-ios**

本地已 `git init` 并推送到 `main`，以后改完只需：

```bash
git add -A && git commit -m "改了什么" && git push
```

> **公开仓库的 macOS 构建免费且不限分钟**。代码里没有家庭码、没有服务器密钥——
> 家庭码是运行时才填的，公开不泄露任何东西。
> 实在不想公开也行：私有仓库每月送 2000 分钟，macOS 按 10 倍扣，等于 **200 分钟**；
> 一次构建约 4 分钟，够跑 40 次。注意私有仓库跑 macOS 需要先绑定付款方式（可以设 $0 上限，不会扣钱）。

### ② 跑构建

Actions → `build-ipa` → **Run workflow**，约 4 分钟。它做四件事：

1. `xcodegen generate` 从 `project.yml` 生成 `.xcodeproj`
2. 挑一个当前系统里真实存在的 iPhone 模拟器（不写死设备名），跑 **25 条解析测试**
3. `xcodebuild archive` 出未签名包
4. 打包成 `SnapLedger-unsigned.ipa` 并作为 artifact 上传

**测试不过就不会产出 ipa**——这是故意的，避免你装上一个识别错金额的版本。

### ③ Windows 上签名安装

1. 装 **iTunes 桌面版**（Apple 官网下载，**不要** Microsoft Store 版）和 [Sideloadly](https://sideloadly.io)
2. iPhone 数据线连电脑，手机上点「信任」
3. Sideloadly 里拖入 `SnapLedger-unsigned.ipa`，Apple ID 填你的免费账号，Start
4. 手机 **设置 → 通用 → VPN与设备管理** → 信任你的开发者证书
5. 手机 **设置 → 隐私与安全性 → 开发者模式** 打开，重启确认（iOS 16+ 必须）
6. 打开 App，给相册权限

### ④ 每 7 天续签

Sideloadly 有 auto-refresh 守护进程，会在证书过期前自动重签，
**前提是电脑开着 + 和手机同一个 Wi-Fi**。电脑常关就换 SideStore（路线 C）。

**重签是覆盖安装，App 里的账目不会丢**（沙盒路径不变）。真正的风险是：过期那天 App 会直接打不开，
如果正好在超市付款完想记账就尴尬——所以第一周先观察一次续签是否成功。

---

## 五、路线 A：有 Mac 时（最快）

```bash
brew install xcodegen && xcodegen generate && open SnapLedger.xcodeproj
```

1. Target → **Minimum Deployments** 设 **iOS 17.0**（`AppIntent`、`onChange(of:)` 都要 17）
2. Build Settings → Swift Language Version → **Swift 5**
   （这堆代码有 `@MainActor` 单例和 GCD 回调，开 Swift 6 严格并发会多出一批和功能无关的 isolation 报错）
3. **Signing & Capabilities** → Team 选你的 Apple ID（Personal Team）
4. iPhone 连上，**设置 → 隐私与安全性 → 开发者模式** 打开
5. `Cmd+B` 编译消错 → `Cmd+U` 跑测试，**25 条全绿再往下写 UI**

> 不用 XcodeGen 的手工路：File → New → Project → App（SwiftUI / Swift），
> 删掉 `ContentView.swift`，把 `SnapLedger/*.swift` 除 `ParserTests.swift` 外拖进去，
> 再 File → New → Target → Unit Testing Bundle 建 `SnapLedgerTests`。

---

## 六、两周计划

| 阶段 | 内容 | 完成标志 |
|---|---|---|
| 第 1–2 天 | 编译通过、跑通 `ParserTests` | 25/25 绿 |
| 第 3–4 天 | 聊天流可用：输入→卡片→确认→落库 | 能连记 10 笔，杀掉 App 重开还在 |
| 第 5–6 天 | 家庭同步：一台创建、另一台输码加入 | 两台手机互见对方的账，删掉的不会回来 |
| 第 7–8 天 | 截图链路：手动截屏 → 打开 App → 自动出卡片 | 微信/支付宝/银行短信三种都对 |
| 第 9–10 天 | 快捷指令只需 1 个动作：`截取屏幕 → 从图片记账` | 双击背面 → 卡片直接出来 |
| 第 11–14 天 | 日/月视图、编辑删除、空态、异常提示 | 自己能连续用一周不别扭 |

先做「能用」，图表和统计放后面。你现在 PWA 里跑通的日/月/年视图，照着重画就行。

---

## 七、三个必须知道的坑

**1. 相册权限可能是「仅选中的照片」**

iOS 14 之后即使用户点了「允许访问所有照片」，也可能落成 limited 模式。
这时 `PHAsset.fetchAssets` 只返回用户勾选的那些，**新截图读不到**，表现为「双击背面没反应」。

- 设置页已做权限状态显示
- 检测到 `.limited` 就调 `PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:)` 让用户补选
- 兜底永远保留：手动截屏 → 打开 App → 点输入框左边的相框按钮

**2. 服务器域名是临时的**

同步地址写在 `SyncEngine.swift` 的 `APIConfig.base`。现在指向临时发布域名，
长期用建议迁到自己的轻量云主机（2C2G 足够，`node server.js` 直接跑，或者换成 Cloudflare Workers + KV 的免费额度）。
迁移只改这一个常量，协议不用动。

**3. 免费签名偶尔会被苹果「吊销」**

同一 Apple ID 短时间内反复申请证书，会触发苹果的风控，表现为所有侧载 App 一夜之间全部打不开。
遇到就等 24 小时再签，或者换一个 Apple ID。**账目在服务器上，不会丢**，别慌着重装。

---

## 八、v1.0 之后值得加的（按性价比排）

1. **锁屏小组件 / 控制中心控件**：本月支出 + 一键记账，iOS 17 `ControlWidget`
2. **微信/支付宝账单导入**：导出的 CSV 邮件附件 → 批量补账，一次补齐历史
3. **图表**：Swift Charts，月度趋势 + 分类占比
4. **iCloud 同步**：把 SyncEngine 换成 CloudKit 共享库，彻底不用自己的服务器（4–6 人日，最容易出意外的一块，所以放最后；**注意这条需要 $99 账号**）
5. **记录编辑**：现在只能确认/丢弃，需要「改一下」的完整表单

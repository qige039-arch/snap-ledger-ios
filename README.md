# 家庭记账 · iOS 原生版

PWA 版的「原生重做」。目标只有一个：**自己家两台 iPhone 用得更顺手**，不做上架。

> 这些 Swift 文件是在 Windows 上写的，编译由 GitHub 的 macOS runner 完成。
> 逻辑（解析引擎、同步协议）是从已经跑过 39 条测试的 JS 代码逐行移植的。

---

## 当前状态（2026-10-31 晚 / v1.0）

| 项 | 状态 |
|---|---|
| 云端编译（GitHub macOS runner） | ✅ 通过，v0.9 见 `run 41184225852`；v1.0 见下方 |
| 解析 + 导入回归用例 | ✅ 全绿（36 条，0 失败） |
| 未签名 ipa | ✅ 已产出，752 KB，在 `dist/SnapLedger-unsigned.ipa` |
| App Intents 是否真进包 | ✅ ipa 里有 `Metadata.appintents/`，说明快捷指令动作会被系统识别 |
| App 图标 | ✅ 已生成，`AppIcon60x60@2x.png` 在包里 |
| **真机安装** | ⬜ 待你在 Windows 上跑 Sideloadly |
| **UI / 相册 / 同步真机联调** | ⬜ 未做 |

### 界面结构（v0.2 重做）

四个 tab，对应网页版的四页：

| Tab | 内容 |
|---|---|
| 记账 | 本月渐变汇总卡（支出大字 + 收入/结余/笔数）+ 聊天流 + 待确认卡片 + 输入栏 |
| 账本 | 日/月/年三粒度、左右翻页、分组列表；**点任意一条可直接改金额/分类/方向，或删掉**；年视图带月度占比条，点月份跳到该月 |
| 统计 | 支出/收入切换、总计·日均·最大一笔、Swift Charts 柱状趋势（月→每天，年→12 个月）、分类排行带百分比 |
| 我的 | 渐变身份卡、邀请码大字 + 一键复制、同步状态、**AI 自动记账四步引导**、相册权限告警、数据导出/导入、关于页 |

设计系统在 `DesignSystem.swift`：动态色（浅色/深色两套）、卡片、自绘分段控件、分类配色、
金额统一 rounded + 等宽数字（滚动不抖）。

### AI 自动记账（v0.6，抄百事 AA 记账）

百事那条快捷指令只有三个动作：**截屏 → 文本「v2」 → 将截屏和文本发送到 App 的 Intent**。
它的引导页是四张编号卡：获取快捷指令 / 设置触发方式 / 开始使用 / 记账设置。

这两样都照做了，但落地方式按我们自己的限制改了两处：

| | 百事 AA | 这里 |
|---|---|---|
| 快捷指令分发 | 官方签名的 iCloud 链接，点一下就装 | **只能走 App Shortcuts**（`ShortcutsLink` 或到快捷指令里搜 App 名）。`.shortcut` 文件方案在 iOS 15 之后是死的 —— 导入必须签名，那个「允许不受信任的快捷指令」开关也被系统移除了 |
| 动作参数 | 截图 + 文本「v2」，要先手动连一次线 | **零参数**：`AddLatestScreenshotIntent` 自己去相册捞最近 10 分钟的截图，加进快捷指令就能跑 |
| 跑完的落点 | 停在原地，弹一个 toast | **`openAppWhenRun = true`：直接把 App 拉到前台，切到记账页，认完自动入账**（v0.8） |
| 带参数版 | 就是上面那条 | 另留 `AddRecordFromImageIntent`（截图 + 标记/备注），给「想记某张旧图」的进阶用法 |
| 后台反馈 | 记账成功后会通知 | 后台 dialog 弹不出来，所以写一条回执，App 回到前台时在聊天流里补一行 + 把那笔账铺出来（能点开改、左滑删） |
| 记账设置 | 选择账本、图片自动存档 | 同样两项，外加存档大小显示与一键清空 |

**v1.0 把「双击背面」从视图里搬出来**

真机反馈：App 跳过来了、顶部显示「正在读刚截的那张图…」，然后没有任何后续。

根因不在识别，在**时序**。v0.9 的链路是这样的：

```
Intent.perform → ScanPending.mark()
   ├ UserDefaults 票据
   └ NotificationCenter.post  ──→ RootView.onReceive → ScanRelay → ChatView.onChange → 读图
```

每一环都假设「视图已经挂载、订阅已经注册」。而 `openAppWhenRun = true` 的顺序是
**先起 App、再跑 perform**：App 冷启动要几百毫秒，`post` 往往早于 `RootView` 的
`.onReceive` 注册 —— 那一声没人听见。UserDefaults 那张票本该兜住，可 `RootView` 只在
`onAppear` / `scenePhase 变化` 时取票，而这两个钩子都已经过去了。票就静静躺着。

结果就是：物理链路全通（App 起来了），逻辑链路断在一个没人监听的广播上。

改法是把执行者从视图搬到常驻单例 `ScanCoordinator`：

```
Intent.perform
   └→ ScanCoordinator.shared.scanFromShortcut()   ← 就在 App 进程里，直接调
        ├ 找图（4 轮回查，0.6s 一次）
        ├ 读图（12s 超时，防 iCloud 图片永不回调 → 界面卡死）
        ├ OCR + 解析 + 入账 + 同步
        └ 发布 banner / pendingRecordIds
             ├ RootView 顶部浮层：任何 tab 都看得见进度和结果
             ├ RootView 收到 focusChat 自增 → 切到记账页
             └ ChatView 挂载时或结果变化时 drain 一次 → 铺成记录行
```

两个附带的好处：

- **晚到也不会漏**：`pendingRecordIds` 是队列，聊天页什么时候来取都行，
  `onAppear` 也会补一次（冷启动时聊天页可能比结果晚到）。
- **进度全局可见**：以前只在聊天页里显示，用户双击完停在「我的」页就什么都看不到 ——
  这正是「卡在一句话上」的观感来源。

另外把「立即读取最新一张截图」（我的 / 引导页）也改成走同一个 coordinator：
原来它把结果交给聊天页，而用户站在「我的」页时聊天页未必挂载，结果直接丢掉。

**v0.9 修「刚截完却说没有截图」**

真机反馈：截图完成了、App 也跳到前台了，但弹出「最近 10 分钟没有截图」。

原因有两个，都在「找图」这一层：

1. **Intent 在 App 起来之前预判了一次「相册里有没有截图」**。双击背面那一刻，刚截的图
   往往还没写进相册、索引也没更新，这一次查询必然是空的 —— 等于提前判死刑。
   现在 Intent 只判权限（被拒绝才拦），找图全部交给前台。
2. **只认带 `photoScreenshot` 标记的图**。快捷指令「截取屏幕」动作存出来的图**不带**这个标记，
   而系统硬件截屏才带。用户走的是快捷指令那条路，所以一张都匹配不上。

改法：

- `latestScreenshot(within:allowAnyImage:)` 两档：先按截图标记找，找不到就退化为窗口内任意一张图。
- 前台 `pickUp` 三轮回查（间隔 0.7s）：相册写入有几百毫秒到一两秒延迟，一次查不到不能下结论。
- 窗口 10 分钟 → 30 分钟；去重仍然保留（`force = false`），两次双击不会记成两笔。
- 删掉 `pickUpOnLaunch()`（打开 App 自动读最近 2 分钟）：它和双击请求会同时到，
  互抢之后后到的那趟被丢掉，就误报「没有截图」。现在只留显式入口。
- 找不到时给出可读原因：权限是「仅选中的照片」→ 直接指向设置开关；否则告诉你
  「相册里最新的一张图是 3 小时前的，不在最近 30 分钟里」。
- 「我的」页新增诊断行「相册里最新一张：12 分钟前（截图）」，并把识别状态显示出来 ——
  原来点了「立即读取最新一张截图」没有任何反馈。

**v0.8 改成「看得见的记账」**

v0.7 是后台跑完、回前台补回执。实测用户的感受还是「双击没反应」——
`openAppWhenRun = false` 时屏幕上什么都不发生，账却已经记上了。

现在的链路是：

```
双击背面
  └→ AddLatestScreenshotIntent（openAppWhenRun = true，App 跳到前台）
       ├ 相册没权限 / 10 分钟内没截图 → 写回执，界面上说清楚
       └ 有截图 → ScanPending.mark()
                    ├ UserDefaults 票据（跨进程）
                    └ 同进程通知（App 先起、Intent 后跑，onAppear 会错过）
                          └→ RootView 切到记账页 → ScanRelay.request()
                               └→ ChatView 读最近 10 分钟的截图 → OCR → 直接入账
                                    └→ 卡片原地变成记录行，可点开改、可左滑删
```

两个细节：

- 双击这条路用 `pickUpFromDoubleTap()`（10 分钟窗口 + `force`），不能用 `pickUpNow()` 的 7 天窗口 ——
  否则三天前的旧截图会被翻出来记成一笔。
- `ScreenshotWatcher.pickUp` 加了 `isPicking` 串行锁。冷启动时「双击请求」和「打开 App 自动读」
  会同时到，不锁就会弹两张一模一样的卡片。

**v0.7 修掉的三个坑**（v0.6 装了但用不了，就是这个原因）：

1. 「安装快捷指令」按钮导出未签名 `.shortcut` —— iOS 15 起导入必须签名，且 `设置 → 快捷指令` 里已经没有「允许不受信任的快捷指令」这个开关，用户点进去只会看到「无法验证」，还找不到原因。已删除该路径。
2. 带参数的 `AddRecordFromImageIntent` 加进快捷指令后一运行就弹「请选择截图」—— 用户得自己插「截屏」并连线，断在这里。新增零参数动作绕开。
3. 后台记账成功但没有任何反馈，双击背面看上去像「没反应」。加 `IntentReport` 回执。

`ScanSettings`（`ScanGuide.swift`）里的两个开关存 UserDefaults，**不进 LedgerDB**：
它们是「这台手机怎么工作」的偏好，不该跟着 LWW 同步到另一台上。
存档写 `Documents/scan-archive/`，长边压到 1200、JPEG 0.72，只进沙盒不进相册。

---

### 曾经修掉的编译错误（记在这里，避免你以为是别的问题）

1. `IntentFile.data` 是 `Data` 不是 `Data?`，不能写 `guard let data = image.data`
2. `d.sync?.pushedAt = max(d.sync?.pushedAt ?? 0, x)` 触发 Swift 独占性检查
   （`overlapping accesses to 'd.sync'`）→ 先取局部变量再赋值
3. `AppShortcut` 的 phrase 里只能插值 `AppEntity` / `AppEnum`，
   写成 `"记 \(\.$text)"` 报 `Invalid parameter type` → 短语里不带参数
4. `View.body` 是 `@ViewBuilder`，里面不能写 `let` + 显式 `return`
   （报 `Cannot use explicit 'return' statement in the body of result builder`）

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
  RecordIntent.swift     App Intents：记一笔 / 截图记账（两个参数，对齐百事那条快捷指令）
  ScanCoordinator.swift  ★ 双击背面的唯一执行者：找图 → 读图 → 识别 → 入账（不依赖视图）
  ScanGuide.swift        ★ AI 自动记账引导页（四步）+ 记账设置 + 截图存档
  ImportSheet.swift      CSV / 粘贴表格导入（表头猜测 + Excel 序列号）
  CalendarHeat.swift     月历热力图
  ChatView.swift         聊天流 + 待确认卡片 + 本月汇总
  BookView.swift         日 / 月 / 年三粒度账本 + 记录编辑
  StatView.swift         统计：汇总网格 + 趋势图 + 分类分布
  MeView.swift           身份、家庭账本、数据、服务设置、关于
  DesignSystem.swift     颜色 / 卡片 / ScopeBar / StatCell / Fmt
  ParserTests.swift      36 条回归用例
  Resources/SnapScan.shortcut  随包分发的快捷指令文件
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

> **push 报 `Connection was reset` 时**：这台机器到 `github.com:443` 时通时不通
> （`api.github.com` 一直可用）。用兜底通道提交，效果等价于一次普通提交，也会触发 CI：
>
> ```bash
> python tools/push_via_api.py -m "改了什么"
> ```
>
> 走完这条路本地会和远端分叉。等 github.com 能连上时，先
> `git fetch origin && git reset --hard origin/main` 对齐，别直接 push。

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

ipa 有两种拿法，选一个：

- **已经拉好了**：`dist/SnapLedger-unsigned.ipa`（210 KB）
- **重新构建后**：Actions 运行页面底部下载 `SnapLedger-unsigned-ipa`

然后：

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

# 大连理工大学校园网自动重连（研究生工位 Windows 版）

大连理工大学研究生工位机用：Dr.COM 校园网门户加 CAS 统一身份认证，掉线之后自动重新登录。后台常驻、开机自启，装完基本不用管。

- 只依赖 Windows 10 / 11 自带的 Windows PowerShell 5.1，不需要 .NET、Python 或任何第三方组件。
- 密码用 Windows 自带的 DPAPI 加密后存在本机，永不明文落盘。
- 只访问学校的门户和 CAS，不往任何第三方服务器发数据。
- 账号要是开了短信二次认证：一次人工登录换一个长期 CAS 会话，之后掉线重连全自动，不用再掏手机。

**在哪个校区验证过**：这套东西是在**大连理工大学开发区校区**的研究生工位机上跑通的。主校区（凌水校区）能不能直接套用**不确定**，没在那边的机器上试过；主校区的同学装完请看一眼日志，卡在哪一步日志里写得很清楚。

**懒得自己敲命令，让 AI 帮你装**：仓库在 [github.com/tyza66/dut-dlut-net-relink-windows](https://github.com/tyza66/dut-dlut-net-relink-windows)，先 clone 下来。把下面这句话连同仓库本地路径一起丢给 AI 即可：

```text
帮我装一下大连理工大学校园网自动重连，仓库地址 https://github.com/tyza66/dut-dlut-net-relink-windows，先把它 clone 下来。步骤：1) 在仓库根目录跑 powershell -ExecutionPolicy Bypass -File install.ps1 -Mode RunKey，学号和密码我发给你；如果这台机器允许建计划任务，就改用默认模式。2) 如果我的账号开了短信二次认证，再跑一次 src\DutNetRelink.ps1 -CasLogin 把长期 CAS 会话换下来，图形验证码和短信验证码我念给你。3) 最后把 src\DutNetRelink.ps1 -Status 的输出给我看一眼。
```

For non-Chinese readers: open PowerShell in this folder, run `powershell -ExecutionPolicy Bypass -File install.ps1 -Mode RunKey`, then type your student ID and password. `-Status` prints the current state; `uninstall.ps1` removes everything.

## 快速开始

**1. 进入本目录。** 下面所有命令都要求在仓库根目录执行。

```powershell
cd D:\Projects\dut-dlut-net-relink-windows
```

**2. 装。** 先按"这台机器不让建计划任务"来跑，这一条在权限卡得最死的工位机上也能用，不需要任何管理员权限：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode RunKey
```

**3. 按提示输学号和密码。** 密码不回显。装的时候它会拿你的账号真登一次 CAS，密码不对当场让你重输，连错三次自动停。

**4. 完事。** 脚本会顺手注册开机启动项、把看门狗拉起来，最后打印一份状态。之后每次开机它自己跑，掉线了自己重连，日志在 `%LOCALAPPDATA%\DutNetRelink\logs\`。

**5. 账号开了二次认证的话还差一步。** CAS 会要求给绑定手机发短信验证码，后台进程没人值守收不了；按下面[账号开了二次认证（短信验证码）怎么办](#账号开了二次认证短信验证码怎么办)跑一次 `-CasLogin` 把会话换下来，之后就真不用管了。

如果这台机器让你建计划任务，用默认模式更好：进程要是挂了，任务计划程序会把它重新拉起来。

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

如果你是管理员，还想让它在开机还没登录时就开始跑，用 `-Mode Startup`。三种方式怎么挑见下一节。

### 安装时你会看到什么

下面是真实输出，这一次是重跑，所以凭据那步直接沿用了已存的，账号做了打码：

```text
DutNetRelink - DLUT campus network auto reconnect
repo: D:\Projects\dut-dlut-net-relink-windows
boot hook: HKCU\...\Run registry entry (no administrator rights needed)

== Credentials
credentials for 22019999 are already stored (scope CurrentUser)
keeping them; pass -Username / -Password to replace them

== Saving settings
config: C:\Users\你\AppData\Local\DutNetRelink\config.json
user  : 22019999   password scope: CurrentUser
interval: 45s   interface: (auto)

== Registering the HKCU Run entry
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
    DutNetRelink = "C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "...\src\DutNetRelink.ps1"
the watchdog starts with your logon and stays resident, with no console window.
note: nothing restarts it if it is ever killed. -Mode Logon (scheduled task) does that, if you can run it elevated.
watchdog running in the background as pid 56208

== One-time second-factor login
no saved CAS session yet: the first reconnect needs an SMS code from you.
DLUT asks this account for a second factor, and a background process cannot read a text message.
Run the login below once, and the watchdog takes over after that.

    D:\Projects\dut-dlut-net-relink-windows\src\DutNetRelink.ps1 -CasLogin

== Current status
config          : C:\Users\你\AppData\Local\DutNetRelink\config.json
username        : 22019999
password        : stored (DPAPI CurrentUser)
credentials     : decryptable for this identity
interval        : 45 s
interface       : (auto)
CAS session     : (none)
active IPv4     : 192.0.2.10
internet        : online
boot persistence: HKCU Run entry (no restart on crash)
--- last log lines ---
2026-09-28 16:32:25 [INFO ] watchdog started (pid 56208, interval 45s, user Dlut)

uninstall with: powershell -ExecutionPolicy Bypass -File "...\uninstall.ps1"
```

用 `-Mode Logon` 时 `boot hook` 会写成 `ONLOGON scheduled task`，注册的是计划任务；`-Mode Startup` 则以 SYSTEM 身份开机就跑。

**重跑 install.ps1 就是更新**：改间隔、改网卡、换账号密码都走它，脚本是幂等的。本机已经存过同一作用域的凭据时，它会先问一句：

```text
credentials for 22019999 are already stored (scope CurrentUser)
Keep them? [Y/n]:
```

回车是保留（只想改间隔就走这个），输 `n` 会重新问学号和密码。不想交互就全用参数：`-Username 22019999 -Password (Read-Host -AsSecureString)`。

## 三种开机自启方式怎么选

| 方式 | 参数 | 什么时候开始跑 | 要什么权限 | 崩了谁拉起 |
| --- | --- | --- | --- | --- |
| 登录时启动（默认） | `-Mode Logon` | 你登录进桌面之后 | 一般不需要管理员 | 计划任务，自动重启 3 次、间隔 1 分钟 |
| 开机即启动 | `-Mode Startup` | 开机，还没登录也在跑 | 管理员 PowerShell | 计划任务，自动重启 |
| 注册表启动项 | `-Mode RunKey` | 你登录进桌面之后 | 什么权限都不要 | 没人，得自己重新跑 |

一句话版本：**先 `-Mode RunKey`，能跑就行；想要崩溃自愈，再想办法上 `-Mode Logon`。** 原因是 `-Mode Logon` 依赖这台机器允许你注册计划任务，而不少工位机的本地组策略直接禁掉了这件事，连最普通的"登录时启动"都注册不了，报 `Access is denied`。这不是脚本的问题，是机器策略。

真撞上了有两条路：右键 Windows PowerShell 选"以管理员身份运行"再跑一次（凭据已经存好，不会再问密码），或者干脆 `-Mode RunKey`，零权限。注册失败时 install.ps1 会先把配置存好，再打印一段说明并以退出码 6 结束，不会让你白输一遍密码。

另外三点值得知道：

- `-Mode Startup` 以 SYSTEM 身份运行，密码按"本机"作用域（`LocalMachine`）加密；另两种按"当前用户"作用域（`CurrentUser`）加密，只有你这个账号解得开。换 `-Mode` 重装会让密码按新作用域重新加密。
- 安装后**这个仓库目录就别挪位置**：启动项里写的是 `src\DutNetRelink.ps1` 的绝对路径。真要挪，先卸载再装。
- 注册表启动项只在你登录之后才启动，进程被杀也没人拉起；要开机未登录就跑，只能走 `-Mode Startup`。

### install.ps1 参数

| 参数 | 说明 |
| --- | --- |
| `-Mode Logon` / `-Mode Startup` / `-Mode RunKey` | 开机自启方式，默认 `Logon` |
| `-Username 22019999` | 学号，不给就交互问 |
| `-Password (Read-Host -AsSecureString)` | 密码，不给就交互问 |
| `-Interval 30` | 检测间隔秒数，5 到 3600，默认 45 |
| `-Interface 以太网2` | 指定网卡名，不给就自动挑默认路由那块 |
| `-NoValidate` | 跳过安装时那次真登录校验 |
| `-NoStart` | 只注册开机启动项，不立即启动 |

## 它怎么工作

每隔 45 秒（可调），脚本用三个系统级强制门户探测点（微软、火狐、苹果）确认网络是不是真通，这些地址只有在上网没被拦截时才返回各自的特征串。一探测到不通，就自动重走一遍校园网登录：

1. 访问门户挑战地址 `http://172.20.30.2:8080/Self/sso_login?...&wlan_user_ip=<当前网卡 IPv4>`，门户 302 跳转到 CAS。
2. 解析 CAS 登录页里的隐藏字段 `lt`、`execution`，这两个每次都是新的，不缓存。
3. 用 CAS 自己的算法 `strEnc(用户名+密码+lt, "1", "2", "3")` 把凭据加密成 `rsa`，连同 `ul`、`pl`、`sl`、`lt`、`execution`、`_eventId` 一起 POST。这个 DES 实现按 `refs/des.js` 逐位移植，并用 6 组黄金向量测住，中文密码也在覆盖范围内。
4. CAS 返回 ticket，门户凭 ticket 放行，脚本再确认真能上网才算这次重连成功。

另外，如果本机存着上次 `-CasLogin` 换来的 CAS 会话，第 1 步就带着它走：CAS 认这个 cookie 会直接发 ticket，上面 2、3 步整个跳过，连密码都不用解。会话过期或者被清了，才回到完整的重登流程。

连续失败不会死磕：退避从 60 秒起、三倍递增，上限 30 分钟，免得把校园网账号撞锁。

## 账号开了二次认证（短信验证码）怎么办

大连理工的 CAS 给一部分账号强制开了二次认证：密码对了还不算，还要给绑定手机发一条短信验证码。门户 `http://172.20.30.2:8080/Self/dashboard` 里翻不到关它的地方，所以只能按这个流程走，分两步：

**1. 一次人工登录，换一个长期会话。** 人在的时候跑一次 `-CasLogin`：它先显示图形验证码，你输完它就让 CAS 给绑定手机发短信，接着要短信验证码；短信对了之后，CAS 有时还会再弹一页「信任设备」，问要不要把这台机器记成可信设备，脚本会自动勾上「信任」并继续，不用你管。成功后 CAS 的会话（`CASTGC` 等 cookie）用 DPAPI 加密存到 `%LOCALAPPDATA%\DutNetRelink\session.json`，跟密码一样只有你这台机器解得开。

**2. 之后全自动。** 每次掉线，看门狗带着这个会话去 CAS，CAS 认这个 cookie 就直接发 ticket 放行，不必再输密码和验证码。会话还剩多少寿命，`-Status` 的 `CAS session` 一行会写出来；过期了再跑一次 `-CasLogin` 就是。

```powershell
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -CasLogin
```

图形验证码会直接画成字符贴在终端里，画不了就打开 `%LOCALAPPDATA%\DutNetRelink\captcha.png` 看。图形验证码输错会当场换一张新的重来；短信发不出来（图形码不对、一分钟内问太多次、账号当天短信次数用完了）它会原样把 CAS 的说法告诉你，不会一直重试。中途不想登，直接回车，干净退出，什么都不会改。想主动丢掉会话：

短信验证码本身还是得你亲手输一次——后台进程收不了短信。这一步只做一次：换上来的会话能顶很久，「信任设备」那页也由脚本自动确认，之后掉线重连全程无人值守。

```powershell
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -ClearSession
```

手头不方便登录就别理它：后台碰到要二次认证的账号，会把重试间隔拉到最长（默认 30 分钟），不去撞 CAS，也绝不会自己偷偷发短信——它没有你的手机。

### 远程 / 无人值守场景：`tools\assisted_mfa_login.ps1`

`-CasLogin` 要人在窗口前敲字（图形验证码 + 短信码）。如果你是通过远程协助或不方便在终端交互，用这个变体：它不开控制台，把两个答案改成文件交接，远程那头（或帮你操作这台机器的人）把答案写进文件就行。

```powershell
# 后台拉起，答案文件在 %TEMP%\DutNetRelinkMfa
Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',
    'D:\Projects\dut-dlut-net-relink-windows\tools\assisted_mfa_login.ps1'
)
```

工作目录里会依次出现：`status.txt`（进度，一行一个时间戳）、`captcha.png`（图形验证码，自己看）、`image_code.txt`（把图形码写进去）、`sms_code.txt`（把短信码写进去）、`result.txt`（最终结果，只写一次）。两个答案属于同一次 CAS 会话，所以进程要一直活着等；`status.txt` 里会告诉你轮到输哪一个。图形码写错会换一张新图重来，短信码写错会写在 `status.txt` 里让你再写一次。会话存进的是看门狗读的同一个 `session.json`（DPAPI，跟运行它的那个账号绑定）。普通用户不需要这个，直接 `-CasLogin` 即可。

## 平时怎么用

装完之后日常只需要看状态：

```powershell
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Status
```

其中 `CAS session` 一行看的是后台免密重连的底气：写着会话的保存时间和 cookie 数量，说明掉线后不用人管；写着 `(none)`，说明这个账号还卡在二次认证上，跑一次上面那节的 `-CasLogin` 就好。

其余几条偶尔用得上：

```powershell
# 立刻检测一次，不在线就重连
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Once

# 不管在不在线，强制登录一次
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Login

# 一次人工登录，把 CAS 换到的长期会话存下来（开了二次认证的账号必跑）
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -CasLogin

# 丢掉保存的 CAS 会话，下次重连重新走一遍认证
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -ClearSession

# 改学号密码（等价于重跑 install.ps1）
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Configure

# 卸载：注册表和计划任务都清掉，凭据和日志默认留着
powershell -ExecutionPolicy Bypass -File uninstall.ps1

# 卸载并连凭据、日志、CAS 会话一起删
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveConfig -RemoveLogs
```

改检测间隔用 `install.ps1 -Interval 30`。注意 `DutNetRelink.ps1 -Interval 30` 只对那一次运行生效，不写进配置。

计划任务方式装的，任务本身可以直接管：

```powershell
Get-ScheduledTask -TaskName DutNetRelink
Get-ScheduledTaskInfo -TaskName DutNetRelink
Stop-ScheduledTask -TaskName DutNetRelink
Start-ScheduledTask -TaskName DutNetRelink
```

注册表方式装的任务列表是空的，改看进程和注册表：

```powershell
Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run | Select-Object DutNetRelink
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*DutNetRelink.ps1*'
```

想临时停掉注册表那个看门狗，结束上面查到的进程即可，重启后它会自己回来。

## 配置

`%LOCALAPPDATA%\DutNetRelink\config.json`，密码字段是 DPAPI 密文：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `Username` | 空 | 学号 |
| `PasswordProtected` | 空 | DPAPI 加密后的密码，base64，永不明文落盘 |
| `CredentialScope` | `CurrentUser` | 加密作用域，SYSTEM 启动时是 `LocalMachine` |
| `IntervalSeconds` | 45 | 检测间隔，5 到 3600 秒 |
| `InterfaceName` | 空 | 指定网卡名（如 `以太网2`），留空自动挑默认路由所在网卡 |
| `MaxAttemptsPerCycle` | 3 | 一次掉线里最多尝试几次登录 |
| `MaxBackoffSeconds` | 1800 | 连续失败时退避的上限，0 表示不退避 |
| `LogRetentionDays` | 14 | 日志保留天数 |

后四个字段在 install.ps1 里没有对应参数，直接改这个 json 即可，看门狗下次循环生效。

## 日志

`%LOCALAPPDATA%\DutNetRelink\logs\dutnetrelink-YYYYMMDD.log`，按天一个文件，超过保留天数自动清理。掉线、重连、失败原因都在里面。

## 排障

- 日志写 `CAS says: Incorrect username and password`：密码错了，重跑 `install.ps1` 或 `-Configure` 改。
- 日志写 `CAS is asking for the SMS second factor; run "DutNetRelink.ps1 -CasLogin" once to renew the session`：账号开了二次认证，而后台收不了短信。按上面[账号开了二次认证（短信验证码）怎么办](#账号开了二次认证短信验证码怎么办)跑一次 `-CasLogin` 把会话换新，这行就不会再出现。
- 日志写 `CAS wants a captcha` 或 `CAS refused the login without an error message`：CAS 要过人机校验。用浏览器登录一次校园网把图形验证码过掉，脚本随后自己会恢复；多次不行就先 `-ClearSession`，再跑一次 `-CasLogin`。
- `-Status` 里 `CAS session` 是 `(none)`：后台还没有可复用的会话，重连会卡在二次认证上，跑一次 `-CasLogin` 即可。
- `-CasLogin` 说短信没发出来：它会照抄 CAS 的原话，常见的是图形验证码不对、一分钟内问太多次、或者账号当天的短信次数用完了，等一会儿再试。
- `-Status` 里 `credentials : NOT decryptable`：任务运行身份和密码加密作用域对不上，用你实际在用的那个 `-Mode` 重装一次。
- 换了网线口或网卡：默认认默认路由那块网卡，也可以把网卡名写进 `InterfaceName`。
- 想手工看门户到 CAS 的链路通不通：`powershell -ExecutionPolicy Bypass -File tools\diagnose_cas_page.ps1`，只读探测，不提交凭据。
- 报 `Access is denied` 且退出码是 6：机器不让注册计划任务，换 `-Mode RunKey` 或用管理员身份重跑。

退出码对照：

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束 |
| 2 | `-Status` 时凭据还没配 |
| 3 | 已有看门狗在跑，本次实例主动让位，属正常 |
| 4 | 没配凭据 |
| 5 | 看门狗内部异常，看日志 |
| 6 | install.ps1 注册计划任务被拒 |

## 自测

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_all_tests.ps1
```

八个套件依次跑，全过则退出码 0：脚本语法与纯 ASCII 检查、DES 黄金向量、CAS 报错解析（离线，直接吃 `refs/` 里抓回来的真页面）、二次认证全流程（图形验证码、发短信、四轮重试、「信任设备」页自动确认，HTTP 全程 mock）、CAS 会话存取（DPAPI cookie jar、路径归一、坏文件容错）、配置存储与 DPAPI 加解密、完整登录链路（用错凭据，预期被拒）、单实例互斥锁与日志落盘。这套测试是给开发用的，平时不用管：二次认证和会话两个套件的 HTTP 全部是假的，不会碰真账号，也不会真发短信。

「信任设备」那页真机抓样子太随机，`refs/cas_trust_device_page.html` 是按 CAS 实际页面结构做的等价样本，二次认证套件拿它验证识别、`check_user_device=true` 提交和整链路走通。

在已经装好、看门狗正在跑的机器上，最后那个 `one cycle` 套件会自己跳过：它要独占单实例互斥锁，而看门狗正占着。跳过不是失败。想看它真跑，先把看门狗停掉再跑。

## 文件

```text
install.ps1            安装 / 更新
uninstall.ps1          卸载
src\DutNetRelink.ps1   看门狗主程序
lib\CasAuth.psm1       门户挑战、CAS 表单、登录、在线探测
lib\CasDes.psm1        CAS 的 strEnc / DES 实现（PowerShell 移植）
lib\ConfigStore.psm1   配置读写与 DPAPI 凭据加解密
lib\CasSession.psm1    CAS 会话（cookie jar）的加密存取
tools\                 测试与诊断脚本
refs\                  抓取的 CAS 页面与原始 JS，仅作比对参考
```

## 已知限制

- 只在**大连理工大学开发区校区**的研究生工位机上验证过。主校区（凌水校区）能不能直接套用不确定，那边的机器没试过。
- 一次人工 `-CasLogin` 的完整成功链路没法自动替你跑，它要有人输短信验证码。装完之后看一眼 `-Status` 和日志：账密正确的话 `CAS session` 会是 `(none)`，跑一次 `-CasLogin` 就有了。
- 二次认证账号的免密重连全押在那个会话上。会话过期后必须有人再跑一次 `-CasLogin`，后台收不了短信；CAS 会话具体能活多久它自己没说，通常几天到几周。
- 计划任务注册没做端到端验证：开发用的机器在策略上禁止当前身份注册计划任务，`Register-ScheduledTask` 和 `schtasks` 都是 `Access is denied`。`-Mode RunKey` 这条链路倒是完整跑通过：写注册表、后台隐藏进程常驻、`-Status` 认得出、卸载清得干净。
- `-Mode RunKey` 只在你登录之后才启动，进程被杀也不会自动拉起。
- 学校要是改了 CAS 表单字段或加密算法，脚本会失效；`refs/` 留了当时的页面和 JS 方便比对。
- 探测点走 HTTP，若哪天校园网开始拦截这些探测地址，可能误判离线；换 `lib\CasAuth.psm1` 里的 `$script:OnlineProbes` 即可。

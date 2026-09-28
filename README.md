# 大理工校园网自动重连（研究生工位 Windows 版）

大连理工大学研究生工位机用：Dr.COM 校园网门户加 CAS 统一身份认证，掉线之后自动重新登录。后台常驻、开机自启，装完基本不用管。

- 只依赖 Windows 10 / 11 自带的 Windows PowerShell 5.1，不需要 .NET、Python 或任何第三方组件。
- 密码用 Windows 自带的 DPAPI 加密后存在本机，永不明文落盘。
- 只访问学校的门户和 CAS，不往任何第三方服务器发数据。

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

如果这台机器让你建计划任务，用默认模式更好：进程要是挂了，任务计划程序会把它重新拉起来。

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

如果你是管理员，还想让它在开机还没登录时就开始跑，用 `-Mode Startup`。三种方式怎么挑见下一节。

### 安装时你会看到什么

下面是真实输出，账号做了打码：

```text
DutNetRelink - DLUT campus network auto reconnect
repo: D:\Projects\dut-dlut-net-relink-windows
boot hook: HKCU\...\Run registry entry (no administrator rights needed)

== Credentials
Username (student ID): 22019999
Password: ************
checking the credentials against CAS from 192.0.2.10 ...
CAS accepted the credentials.

== Saving settings
config: C:\Users\你\AppData\Local\DutNetRelink\config.json
user  : 22019999   password scope: CurrentUser
interval: 45s   interface: (auto)

== Registering the HKCU Run entry
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
    DutNetRelink = "C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "...\src\DutNetRelink.ps1"
the watchdog starts with your logon and stays resident, with no console window.
note: nothing restarts it if it is ever killed. -Mode Logon (scheduled task) does that, if you can run it elevated.

== Current status
config          : C:\Users\你\AppData\Local\DutNetRelink\config.json
username        : 22019999
password        : stored (DPAPI CurrentUser)
credentials     : decryptable for this identity
interval        : 45 s
interface       : (auto)
active IPv4     : 192.0.2.10
internet        : online
boot persistence: HKCU Run entry (no restart on crash)

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

连续失败不会死磕：退避从 60 秒起、三倍递增，上限 30 分钟，免得把校园网账号撞锁。

## 平时怎么用

装完之后日常只需要看状态：

```powershell
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Status
```

其余几条偶尔用得上：

```powershell
# 立刻检测一次，不在线就重连
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Once

# 不管在不在线，强制登录一次
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Login

# 改学号密码（等价于重跑 install.ps1）
powershell -ExecutionPolicy Bypass -File src\DutNetRelink.ps1 -Configure

# 卸载：注册表和计划任务都清掉，凭据和日志默认留着
powershell -ExecutionPolicy Bypass -File uninstall.ps1

# 卸载并连凭据、日志一起删
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
- 日志写 `CAS wants a captcha` 或 `CAS refused the login without an error message`：连续失败后 CAS 会要验证码，这时候脚本进不去。用浏览器登录一次校园网把验证码过掉，脚本随后自己会恢复。
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

六个套件依次跑，全过则退出码 0：脚本语法与纯 ASCII 检查、DES 黄金向量、CAS 报错解析（离线，直接吃 `refs/` 里抓回来的真页面）、配置存储与 DPAPI 加解密、完整登录链路（用错凭据，预期被拒）、单实例互斥锁与日志落盘。这套测试是给开发用的，平时不用管。

## 文件

```text
install.ps1            安装 / 更新
uninstall.ps1          卸载
src\DutNetRelink.ps1   看门狗主程序
lib\CasAuth.psm1       门户挑战、CAS 表单、登录、在线探测
lib\CasDes.psm1        CAS 的 strEnc / DES 实现（PowerShell 移植）
lib\ConfigStore.psm1   配置读写与 DPAPI 凭据加解密
tools\                 测试与诊断脚本
refs\                  抓取的 CAS 页面与原始 JS，仅作比对参考
```

## 已知限制

- 登录成功链路没法在这里替你验，需要真实账号密码。装完看一眼 `-Status` 和日志确认即可。
- 计划任务注册没做端到端验证：开发用的机器在策略上禁止当前身份注册计划任务，`Register-ScheduledTask` 和 `schtasks` 都是 `Access is denied`。`-Mode RunKey` 这条链路倒是完整跑通过：写注册表、后台隐藏进程常驻、`-Status` 认得出、卸载清得干净。
- `-Mode RunKey` 只在你登录之后才启动，进程被杀也不会自动拉起。
- 学校要是改了 CAS 表单字段或加密算法，脚本会失效；`refs/` 留了当时的页面和 JS 方便比对。
- 探测点走 HTTP，若哪天校园网开始拦截这些探测地址，可能误判离线；换 `lib\CasAuth.psm1` 里的 `$script:OnlineProbes` 即可。

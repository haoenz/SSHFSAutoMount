# SSHFSAutoMount

SSHFS-Win 远程目录自动挂载 PowerShell 模块：把 `~/.ssh/config.d/` 中定义的 SSH Host 别名对应的远程目录挂载为本地盘符，并通过计划任务实现登录时自动挂载；另含按主机可达性自动切换直连/跳板配置的 `Update-SSHHostConfig`。

## 功能一览

| 函数 | 作用 |
|---|---|
| `Mount-SSHFSDrive` | 挂载 `~/.ssh/config.d/<Name>.conf` 对应的远程目录为本地盘符 |
| `Register-SSHFSAutoMount` | 注册「登录时自动更新配置并挂载」的计划任务（任务名 `SSHFSAutoMount-<Name>`） |
| `Get-SSHFSAutoMount` | 查询本模块注册的所有计划任务，含上次运行时间与结果 |
| `Unregister-SSHFSAutoMount` | 删除计划任务，可选顺带断开映射与清理残留 |
| `Update-SSHHostConfig`（别名 `uhc`） | 按主机可达性自动更新 `~/.ssh/config.d/<Name>.conf`，自动选择直连或跳板配置 |

## 环境要求

- **PowerShell 7 (pwsh)**：模块要求 `PowerShellVersion = 7.0`，仅支持 Core 版
- **WinFsp + SSHFS-Win**：模块通过 WinFsp 的 `sshfs.k` 网络提供程序挂载。`sshfs.k` 是 SSHFS-Win 提供的密钥认证（key-based）变体，UNC 前缀为 `\\sshfs.k\`；区别于密码认证的 `sshfs.r`。需安装含该提供程序的 SSHFS-Win 版本
- SSH 密钥认证已配置好（模块不做任何交互式认证）

## 安装

把模块目录放到 PowerShell 模块路径下，例如：

```powershell
$moduleDir = "$HOME\Documents\PowerShell\Modules\SSHFSAutoMount"
# 将 SSHFSAutoMount.psd1 与 SSHFSAutoMount.psm1 放入上述目录后：
Import-Module SSHFSAutoMount
```

> 注意：模块根目录的 `hostProfiles.json`（可达性探测候选表）属隐私文件，已加入 `.gitignore` 不随仓库分发，新环境需按下文 `Update-SSHHostConfig` 一节的格式手动创建，否则模块导入会因缺少该文件而失败。

## 前置准备：ssh config

模块从 `~/.ssh/config.d/<Name>.conf` 读取连接信息，解析 `HostName` / `User` / `Port`，构造 `\\sshfs.k\<user>@<host>` 挂载。例如 `~/.ssh/config.d/home.conf`：

```
Host home
    HostName 192.168.1.10
    User yiyan
    Port 22
```

解析遵循 ssh 语义：

- 支持通配符 Host（`*`、`?`）与负模式（`!pattern`），先命中的块优先，后续块不覆盖
- `Host *` 等通配块可提供默认值；`Match` 块视为不适用（仅作块边界）
- 文件中完全没有 `Host` 行时，整个文件视为一个配置块
- 缺省时 `HostName` 取别名本身、`User` 取当前 Windows 用户名、`Port` 取 22

> 修改过 ssh config 后，无需改模块：下次挂载时按新配置解析。

## 快速上手

```powershell
# 1. 手动挂载（自动从 Z 往前选盘符，显示名默认为别名）
Mount-SSHFSDrive home

# 2. 指定盘符与显示名
Mount-SSHFSDrive home -DriveLetter Y -Label home

# 3. 手动按可达性更新配置（直连/跳板自动切换，探测结果逐行显示 ✅/❌）
Update-SSHHostConfig home
uhc bhnas           # 别名等价

# 4. 注册登录时自动更新配置并挂载
Register-SSHFSAutoMount home

# 5. 查看已注册任务及上次运行结果
Get-SSHFSAutoMount
Get-SSHFSAutoMount home

# 6. 移除（仅删任务 / 彻底清理）
Unregister-SSHFSAutoMount home
Unregister-SSHFSAutoMount home -Dismount -RemoveState   # 顺带断开映射、清理状态与注册表残留
```

## 各函数说明

### Mount-SSHFSDrive

```
Mount-SSHFSDrive <Name> [-DriveLetter <char>] [-Label <string>] [-Provider <string>]
                       [-MaxRetries <int>] [-RetryInterval <int>] [-Log] [-Force]
```

| 参数 | 说明 |
|---|---|
| `-DriveLetter` | 挂载盘符；留空时自动从 Z 往前找第一个可用盘符（跳过 A/B） |
| `-Label` | 资源管理器中盘符的显示名，默认与别名相同 |
| `-Provider` | WinFsp 提供程序名，默认 `sshfs.k` |
| `-MaxRetries` / `-RetryInterval` | 挂载失败重试次数（默认 12）与间隔秒数（默认 5），应对登录时 sshfs 服务未就绪 |
| `-Log` | 过程写入 `~/.ssh/sshfsmount/logs/<Name>.log`，用于排查计划任务静默运行的失败 |
| `-Force` | 指定盘符被其他别名的 SSHFS 挂载占用时，允许强行断开并占用；默认拒绝以防误伤 |

返回挂载结果对象：`Name` / `DriveLetter` / `RemotePath` / `Label`。

### Register-SSHFSAutoMount

```
Register-SSHFSAutoMount <Name> [-DriveLetter <char>] [-Label <string>]
                                [-TaskName <string>] [-Description <string>]
```

- 任务在**用户登录时**触发，以当前用户身份运行，显式允许电池供电、执行时限 10 分钟
- 计划任务命令固化当前 pwsh 路径（登录环境的 PATH 可能与交互 shell 不同）
- 盘符留空时任务执行时自动选盘符；任务自带 `-Log`
- 支持 `-WhatIf` 预览
- `Name` / `Label` 不能含引号（会损坏任务命令）；`Name` 不能含 `\ / : * ? " < > |`

> 修改过模块或任务相关逻辑后，需重新执行 `Register-SSHFSAutoMount <Name>` 覆盖注册才生效。

### Update-SSHHostConfig（别名 uhc）

```
Update-SSHHostConfig <Name> [-ConfigDir <string>] [-Port <int>] [-TimeoutMs <int>]
```

- 探测候选表维护在模块根目录 `hostProfiles.json`。**该文件含内网/跳板机地址，属隐私文件，已加入 `.gitignore` 不入库**；新增 Host 直接编辑该 JSON，每个候选显式写全 `Address` / `ProxyJump` / `User` 三字段（`ProxyJump` 可为 `null`，保证 StrictMode 下取值安全）。结构示例：

  ```json
  {
      "<Host 别名>": [
          { "Address": "192.168.1.10",  "ProxyJump": null,     "User": "用户名" },
          { "Address": "10.0.0.10",     "ProxyJump": null,     "User": "用户名" },
          { "Address": "10.0.0.10",     "ProxyJump": "跳板别名", "User": "用户名" }
      ]
  }
  ```

- 按优先级顺序探测 TCP 端口（默认 22，单次超时 2 秒），首个可连者胜出写入配置；全部不可连时取列表最后一项（通常带 ProxyJump）作为默认值
- 配置内容未变化时跳过重写（不改 mtime）
- 返回 `$true` = 配置已就绪（新写入或无变化）；未知 Host 名称输出警告并返回 `$false`，不中断调用方（便于在计划任务中与挂载串联）
- 登录计划任务（`Register-SSHFSAutoMount`）会自动先执行本函数再挂载，网络环境变化时无需手动改配置

### Get-SSHFSAutoMount

```
Get-SSHFSAutoMount [[-Name] <string>] [-TaskName <string>]
```

列出任务名、Host 别名、状态、上次运行时间（`LastRunTime`）、上次结果（`LastResult`，十六进制）、触发器与完整命令。`-TaskName` 用于查询注册时用 `-TaskName` 自定义过名称的任务。

### Unregister-SSHFSAutoMount

```
Unregister-SSHFSAutoMount <Name> [-TaskName <string>] [-Dismount] [-RemoveState]
```

- 默认只删除计划任务
- `-Dismount`：顺带断开该别名的网络映射（含配置地址变更前旧 UNC 的映射）
- `-RemoveState`：顺带删除状态文件 `~/.ssh/sshfsmount/<Name>.json` 与 MountPoints2 中盘符显示名注册表残留
- ssh 配置文件已被删除时自动降级，仅清理注册表/状态残留

## 关键行为设计

### 幂等与单挂载约束

SSHFS-Win 对同一 `user@host` 目标**只允许一个活动挂载**，重复挂载报错 64/67。模块挂载前会扫描现有映射：目标已映射到某盘符时直接复用该盘符（即使与请求的盘符不同也会提示并复用），保证命令可重复执行。

### 假失败兜底

SSHFS-Win 的挂载是异步的：冷启动时 `net use` 可能返回错误 67（找不到网络名）但映射实际已在后台建立。模块在 `net use` 报错后会验证盘符实际可用性，可用即视为成功。**判断挂载成败应看盘符实际可用性（`Test-Path` / `net use` 列表），不能只看 `net use` 退出码。**

### 盘符不漂移（失效映射原地替换）

挂载成功后写状态文件 `~/.ssh/sshfsmount/<Name>.json`（别名 → 盘符/UNC/显示名）。之后不传 `-DriveLetter` 时优先复用上次盘符：

- 盘符空闲 → 直接复用
- 已挂载同一目标 → 幂等复用
- 配置里主机地址已变、盘符仍映射着状态记录的旧 UNC → 识别为失效映射，原地删除重挂，**盘符不漂移，既有 `Y:\` 路径继续有效**；顺带清除旧 UNC 的 MountPoints2 显示名残留
- 盘符被其他目标或本地设备占用 → 回退自动选盘符，不会误删

兼容 v1.0（无状态文件时期）：通过资源管理器 MountPoints2 中显示名残留（`_LabelFromReg` = 别名）识别本别名旧挂载的盘符。

### 保护机制

- 指定盘符当前映射着**其他别名**的 SSHFS 挂载时，未经 `-Force` 拒绝自动断开
- 指定盘符被本地设备占用（非网络映射）时直接报错
- 旧映射断开失败（被进程占用）时立即报错并提示手动清理命令，避免空转重试

## 数据与日志位置

| 路径 | 说明 |
|---|---|
| `~/.ssh/config.d/<Name>.conf` | ssh 配置源（`Update-SSHHostConfig` 的写入目标） |
| 模块根目录 `hostProfiles.json` | 可达性探测候选表（别名 → 候选列表）；**隐私文件，已 gitignore 不入库** |
| `~/.ssh/sshfsmount/<Name>.json` | 挂载状态（别名 → 盘符/UNC/显示名/更新时间） |
| `~/.ssh/sshfsmount/logs/<Name>.log` | 挂载日志（`-Log` 时写入，超 512KB 自动清空重写） |
| `HKCU:\...\Explorer\MountPoints2\##sshfs.k#*` | 盘符显示名注册（模块写入与清理） |
| 计划任务 `SSHFSAutoMount-*` | 登录自动挂载任务 |

## 排障

- **登录后没挂上**：先看 `Get-SSHFSAutoMount` 的 `LastRunTime` / `LastResult`，再看 `~/.ssh/sshfsmount/logs/<Name>.log`（任务注册时自带 `-Log`）
- **提示盘符映射着其他 SSHFS 挂载**：换盘符，或确认后加 `-Force`
- **提示旧映射断开失败**：手动执行 `net use <盘符>: /delete /y`
- **对失联挂载点 `Test-Path` 卡顿**：Windows 固有行为，对失联的 SSHFS 挂载点 `Test-Path` 可能阻塞数十秒，模块已尽量避免触发但无法完全规避
- **模块内部函数测试**：需在模块会话内执行，如 `& (Get-Module SSHFSAutoMount) { <内部函数> }`

## 版本

- **1.1.0**：可靠性修复（幂等复用、假失败兜底、失效映射原地替换）、`-Force` 保护、挂载日志、通配/负模式 Host、`LastRunTime`/`LastResult` 查询、`-Dismount`/`-RemoveState` 清理；新增 `Update-SSHHostConfig`（`uhc`）按主机可达性自动切换直连/跳板，登录计划任务改为先更新配置再挂载

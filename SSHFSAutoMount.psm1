# ============================================================
# SSHFSAutoMount.psm1
# SSHFS-Win (sshfs.k) 远程目录自动挂载模块
#
# 功能:
#   Mount-SSHFSDrive      挂载 ~/.ssh/config.d/<Name>.conf 对应远程目录
#   Register-SSHFSAutoMount  注册登录时自动挂载的计划任务
#   Get-SSHFSAutoMount    查询本模块注册的所有计划任务
#   Unregister-SSHFSAutoMount  删除自动挂载计划任务
#
# 依赖: PowerShell 7 (pwsh), 计划任务相关函数使用 ScheduledTasks 模块
# ============================================================

Set-StrictMode -Version Latest

$script:SSHFSProvider = 'sshfs.k'   # WinFsp SSHFS 网络提供程序名 (UNC 前缀, 勿改)
$script:TaskPrefix    = 'SSHFSAutoMount-'
$script:StateDir      = Join-Path $env:USERPROFILE '.ssh\sshfsmount'   # 挂载状态文件目录

# ---------- 内部函数: 解析 ssh config.d 配置 ----------
function Resolve-SSHFSTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [string]$Provider = $script:SSHFSProvider
    )

    $confFile = Join-Path $env:USERPROFILE ".ssh\config.d\$Name.conf"
    if (-not (Test-Path -LiteralPath $confFile)) {
        throw "SSH 配置文件不存在: $confFile"
    }

    $user = $null; $hostName = $null; $port = 22
    $lines = Get-Content -LiteralPath $confFile
    $blockLines = @(); $inBlock = $false

    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^(Host|Match)\b') {
            if ($inBlock) { break }                    # 进入下一个块, 结束
            if ($t -match '^Host\s+(.+)$') {
                if (($Matches[1] -split '\s+') -contains $Name) { $inBlock = $true }
            }
        } elseif ($inBlock) {
            if ($t -and -not $t.StartsWith('#')) { $blockLines += $t }
        }
    }

    # 文件里没有 "Host <Name>" 块时, 把整个文件当做一个配置块
    if (-not $inBlock) {
        $blockLines = @($lines | ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    foreach ($l in $blockLines) {
        if     ($l -match '^HostName\s+(.+)$') { $hostName = $Matches[1].Trim() }
        elseif ($l -match '^User\s+(\S+)\s*$') { $user = $Matches[1] }
        elseif ($l -match '^Port\s+(\d+)\s*$') { $port = [int]$Matches[1] }
    }
    if (-not $hostName) { $hostName = $Name }
    if (-not $user)     { $user = $env:USERNAME }

    $unc = "\\$Provider\$user@$hostName"
    if ($port -ne 22) { $unc += "!$port" }

    return [pscustomobject]@{
        Name     = $Name
        User     = $user
        HostName = $hostName
        Port     = $port
        Provider = $Provider
        UNC      = $unc
        ConfFile = $confFile
    }
}

# ---------- 内部函数: 查询某盘符当前映射目标 ----------
function Get-DriveTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)

    $out = net use 2>&1 | Out-String
    foreach ($ln in ($out -split "`r?`n")) {
        if ($ln -match "^\s*$([regex]::Escape($DriveLetter)):\s+(\S+)") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ---------- 内部函数: 查询所有盘符 -> 目标 UNC 映射表 ----------
function Get-DriveTargetMap {
    $out = net use 2>&1 | Out-String
    $map = @{}
    foreach ($ln in ($out -split "`r?`n")) {
        if ($ln -match '^\s*([A-Z]):\s+(\S+)') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

# ---------- 内部函数: 设置资源管理器盘符显示名 ----------
function Set-SSHFSDriveLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Unc
    )
    try {
        $keyName = ($Unc -replace '\\', '#')   # \\sshfs.k\user@host -> ##sshfs.k#user@host
        $keyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$keyName"
        New-Item -Path $keyPath -Force | Out-Null
        New-ItemProperty -Path $keyPath -Name '_LabelFromReg' -Value $Label -PropertyType String -Force | Out-Null
    } catch {
        Write-Warning "设置盘符显示名失败(不影响挂载): $_"
    }
}

# ---------- 内部函数: 挂载状态文件 (记录 别名 -> 盘符/UNC, 用于失效映射识别与替换) ----------
function Get-MountState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $f = Join-Path $script:StateDir "$Name.json"
    if (Test-Path -LiteralPath $f) {
        try { return Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-MountState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$Unc,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        [pscustomobject]@{
            Name        = $Name
            DriveLetter = $DriveLetter
            Unc         = $Unc
            Label       = $Label
            UpdatedAt   = (Get-Date).ToString('s')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:StateDir "$Name.json") -Encoding utf8
    } catch {
        Write-Warning "写入挂载状态失败(不影响挂载): $_"
    }
}

# 清除旧 UNC 在资源管理器中的显示名注册表项(地址变更后残留会指向失效目标)
function Remove-MountPoints2Label {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Unc)
    try {
        $keyName = ($Unc -replace '\\', '#')
        $keyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$keyName"
        if (Test-Path $keyPath) { Remove-Item -Path $keyPath -Force }
    } catch { }
}

# ---------- 内部函数: 挂载日志 (计划任务隐藏窗口运行时, 事后排查登录挂载失败的唯一线索) ----------
function Write-MountLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        $logDir = Join-Path $script:StateDir 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $logFile = Join-Path $logDir "$Name.log"
        # 单文件超过 512KB 时清空重写, 防止无限增长
        if ((Test-Path -LiteralPath $logFile) -and ((Get-Item -LiteralPath $logFile).Length -gt 512KB)) {
            Set-Content -LiteralPath $logFile -Value '' -Encoding utf8
        }
        Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8
    } catch { }
}

# ---------- 内部函数: 从 Z 往前找第一个可用盘符 ----------
function Get-AvailableDriveLetter {
    # Z=90 递减到 C=67 (跳过 A/B, 避免软驱/系统保留盘符)
    for ($c = 90; $c -ge 67; $c--) {
        $letter = [char]$c
        # 本地设备占用(Test-Path 为真)或已网络映射(Get-DriveTarget 有值)都算不可用
        if (-not (Test-Path "${letter}:\") -and -not (Get-DriveTarget -DriveLetter $letter)) {
            return $letter
        }
    }
    throw '未找到可用盘符: Z..C 均被占用'
}

# ---------- 内部函数: 无状态记录时, 按资源管理器显示名残留识别本别名旧挂载的盘符 ----------
# 兼容 v1.0 时期挂载(尚无状态文件)的识别: MountPoints2 中 ##sshfs.k#* 键的 _LabelFromReg 即别名
function Find-LegacyAliasDrive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
        if (-not (Test-Path $base)) { return $null }
        $map = Get-DriveTargetMap
        foreach ($key in (Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
            if ($key.PSChildName -notlike "##$script:SSHFSProvider#*") { continue }
            $p = Get-ItemProperty -Path $key.PSPath -Name '_LabelFromReg' -ErrorAction SilentlyContinue
            if (-not $p -or $p._LabelFromReg -ne $Name) { continue }
            $oldUnc = $key.PSChildName -replace '#', '\'
            foreach ($letter in $map.Keys) {
                if ($map[$letter] -ieq $oldUnc) {
                    Write-Verbose "识别到本别名旧挂载: ${letter}: -> $oldUnc (来自资源管理器显示名残留)"
                    return $letter
                }
            }
        }
    } catch { }
    return $null
}

# ---------- 内部函数: 为别名选择挂载盘符 (优先复用该别名上次使用的盘符) ----------
function Select-MountDriveLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Unc
    )

    $state = Get-MountState -Name $Name
    if ($state -and $state.DriveLetter) {
        $letter = $state.DriveLetter
        $cur = Get-DriveTarget -DriveLetter $letter
        if (-not $cur) {
            if (Test-Path "${letter}:\") {
                Write-Verbose "状态记录 ${letter}: 但被本地设备占用, 回退自动选盘符"
            } else {
                return $letter    # 盘符空闲, 直接复用
            }
        }
        elseif ($cur -ieq $Unc) {
            return $letter        # 已挂载同一目标, 复用 (幂等)
        }
        elseif ($cur -ieq $state.Unc) {
            # 盘符仍映射着上次挂载的 UNC, 而配置里的地址已变
            # -> 旧映射即失效映射, 复用盘符以便后续删除重挂, 保持 Z:\ 路径不漂移
            Write-Verbose "配置地址已变更 ($($state.Unc) -> $Unc), 复用 ${letter}: 并替换失效映射"
            return $letter
        } else {
            Write-Verbose "${letter}: 当前映射到 $cur, 与本模块记录不符(可能被手动占用), 回退自动选盘符"
        }
    }

    # 无状态记录(v1.0 时期挂载): 通过资源管理器显示名残留识别本别名旧挂载
    $legacy = Find-LegacyAliasDrive -Name $Name
    if ($legacy) { return $legacy }

    return Get-AvailableDriveLetter
}

# ---------- 1. 挂载 ----------
function Mount-SSHFSDrive {
    <#
    .SYNOPSIS
    挂载 ~/.ssh/config.d/<Name>.conf 对应的 SSHFS 远程目录为本地盘符。

    .DESCRIPTION
    从 ~/.ssh/config.d/<Name>.conf 解析 HostName / User / Port,
    构造 \\sshfs.k\<user>@<host> 并挂载到指定盘符,
    同时把资源管理器中的盘符显示名设为指定标签。

    自动选盘符时优先复用该别名上次使用的盘符(记录于 ~/.ssh/sshfsmount/<Name>.json)。
    若配置中的主机地址变更, 上次盘符上的旧映射会被识别为失效映射并原地替换,
    保证盘符不漂移、既有 Z:\ 路径继续有效。

    .PARAMETER Name
    ssh config.d 中的 Host 别名(如 home), 对应文件 home.conf。

    .PARAMETER DriveLetter
    挂载盘符。留空(不传)时自动从 Z 往前找第一个可用盘符。

    .PARAMETER Label
    资源管理器盘符显示名, 默认与 Name 相同。

    .PARAMETER Provider
    WinFsp SSHFS 网络提供程序名, 默认 sshfs.k。

    .PARAMETER MaxRetries
    挂载失败重试次数(登录时 sshfs 服务可能未就绪), 默认 12。

    .PARAMETER RetryInterval
    重试间隔秒数, 默认 5。

    .PARAMETER Log
    将挂载过程追加写入日志文件 ~/.ssh/sshfsmount/logs/<Name>.log,
    便于排查计划任务静默运行(-WindowStyle Hidden)时的失败原因。

    .EXAMPLE
    Mount-SSHFSDrive home

    .EXAMPLE
    Mount-SSHFSDrive home -DriveLetter Y -Label home
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [string]$DriveLetter,
        [string]$Label,
        [string]$Provider = $script:SSHFSProvider,
        [int]$MaxRetries = 12,
        [int]$RetryInterval = 5,
        [switch]$Log
    )

    if (-not $Label) { $Label = $Name }

    $target = Resolve-SSHFSTarget -Name $Name -Provider $Provider
    $unc = $target.UNC

    if (-not $DriveLetter) {
        # 优先复用本别名上次使用的盘符; 上次盘符上是失效旧映射时, 同样复用以便原地替换
        $DriveLetter = Select-MountDriveLetter -Name $Name -Unc $unc
        Write-Verbose "未指定盘符, 自动选择: ${DriveLetter}:"
    }
    Write-Verbose "目标: $unc  ->  ${DriveLetter}:"
    if ($Log) { Write-MountLog -Name $Name -Message "开始挂载: $unc -> ${DriveLetter}: (最多重试 $MaxRetries 次)" }

    # SSHFS-Win 同一 user@host 目标只允许一个活动挂载, 重复挂载会报错 64/67。
    # 目标已映射到某盘符时直接复用, 保证命令可重复执行(幂等)。
    $map = Get-DriveTargetMap
    foreach ($k in $map.Keys) {
        if ($map[$k] -ieq $unc) {
            if ($k -ne $DriveLetter) {
                Write-Warning "目标已映射到 ${k}: (SSHFS-Win 同目标仅支持一个挂载), 忽略 ${DriveLetter}: 直接复用 ${k}:"
            } else {
                Write-Verbose "${k}: 已映射到 $unc, 无需重复挂载"
            }
            Set-SSHFSDriveLabel -DriveLetter $k -Label $Label -Unc $unc
            Save-MountState -Name $Name -DriveLetter $k -Unc $unc -Label $Label
            if ($Log) { Write-MountLog -Name $Name -Message "目标已映射到 ${k}:, 直接复用(幂等)" }
            return [pscustomobject]@{
                Name        = $Name
                DriveLetter = $k
                RemotePath  = $unc
                Label       = $Label
            }
        }
    }

    $mounted = $false
    for ($i = 1; $i -le $MaxRetries; $i++) {
        $cur = Get-DriveTarget -DriveLetter $DriveLetter
        if ($cur) {
            if ($cur -ieq $unc) {
                Write-Verbose "${DriveLetter}: 已映射到 $unc, 无需重复挂载"
                if ($Log) { Write-MountLog -Name $Name -Message "${DriveLetter}: 已映射到 $unc, 无需重复挂载(幂等)" }
                $mounted = $true
                break
            }
            Write-Warning "${DriveLetter}: 当前映射到 $cur, 先断开旧映射"
            net use "${DriveLetter}:" /delete /y | Out-Null
            Start-Sleep -Seconds 1
            # 断开失败(常见于映射被进程占用)时立即报错, 避免重试循环空转 MaxRetries 轮
            if (Get-DriveTarget -DriveLetter $DriveLetter) {
                $msg = "${DriveLetter}: 旧映射 $cur 断开失败(可能被进程占用), 请手动执行: net use ${DriveLetter}: /delete /y"
                if ($Log) { Write-MountLog -Name $Name -Message $msg }
                throw $msg
            }
            Remove-MountPoints2Label -Unc $cur   # 清掉旧目标的资源管理器显示名残留
        } elseif (Test-Path "${DriveLetter}:\") {
            throw "${DriveLetter}: 被本地设备占用(非网络映射), 请先释放"
        }

        Write-Verbose "尝试挂载 ($i/$MaxRetries): net use ${DriveLetter}: $unc"
        $err = net use "${DriveLetter}:" "$unc" /persistent:yes 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $mounted = $true
            break
        }
        # SSHFS-Win 的挂载是异步的: net use 可能返回错误 67(找不到网络名) 这种"假失败",
        # 但映射已在后台建立成功。先验证盘符实际可用性, 可用即视为成功。
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath "${DriveLetter}:\" -ErrorAction SilentlyContinue) {
            $mounted = $true
            Write-Warning "net use 返回错误($($err.Trim())), 但 ${DriveLetter}: 已实际挂载, 视为成功"
            if ($Log) { Write-MountLog -Name $Name -Message "net use 返回错误($($err.Trim())), 但 ${DriveLetter}: 已实际挂载, 视为成功" }
            break
        }
        if ($i -lt $MaxRetries) {
            Write-Verbose "挂载失败, ${RetryInterval} 秒后重试: $($err.Trim())"
            if ($Log) { Write-MountLog -Name $Name -Message "挂载失败($i/$MaxRetries): $($err.Trim())" }
            Start-Sleep -Seconds $RetryInterval
        } else {
            # 最后一轮兜底: 映射条目可能刚注册而连接尚未完全就绪, Test-Path 可能为 false
            if (Get-DriveTarget -DriveLetter $DriveLetter) {
                $mounted = $true
                Write-Warning "net use 返回错误($($err.Trim())), 但 ${DriveLetter}: 已映射, 视为成功"
                if ($Log) { Write-MountLog -Name $Name -Message "net use 返回错误($($err.Trim())), 但 ${DriveLetter}: 已映射, 视为成功" }
                break
            }
            if ($Log) { Write-MountLog -Name $Name -Message "挂载最终失败: $($err.Trim())" }
            throw "挂载失败: $($err.Trim())"
        }
    }
    if (-not $mounted) { throw '挂载失败' }

    # 设置资源管理器盘符显示名
    Set-SSHFSDriveLabel -DriveLetter $DriveLetter -Label $Label -Unc $unc
    Save-MountState -Name $Name -DriveLetter $DriveLetter -Unc $unc -Label $Label
    if ($Log) { Write-MountLog -Name $Name -Message "挂载成功: $unc -> ${DriveLetter}:" }

    return [pscustomobject]@{
        Name        = $Name
        DriveLetter = $DriveLetter
        RemotePath  = $unc
        Label       = $Label
    }
}

# ---------- 2. 注册计划任务 ----------
function Register-SSHFSAutoMount {
    <#
    .SYNOPSIS
    注册"登录时自动挂载"的计划任务, 任务名默认为 SSHFSAutoMount-<Name>。

    .PARAMETER Name
    ssh config.d 中的 Host 别名(如 home)。

    .PARAMETER DriveLetter
    挂载盘符。留空(不传)时, 计划任务执行时会自动从 Z 往前找第一个可用盘符。

    .PARAMETER Label
    盘符显示名, 默认与 Name 相同。

    .PARAMETER TaskName
    计划任务名, 默认 SSHFSAutoMount-<Name>。

    .EXAMPLE
    Register-SSHFSAutoMount home

    .EXAMPLE
    Register-SSHFSAutoMount home -DriveLetter Y

    .EXAMPLE
    Register-SSHFSAutoMount home -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [string]$DriveLetter,
        [string]$Label,
        [string]$TaskName,
        [string]$Description
    )

    if (-not $Label) { $Label = $Name }

    # Name/Label 会以单引号字面量嵌入计划任务命令, 含引号会生成损坏的任务命令; Name 还会用作任务名
    foreach ($v in @($Name, $Label)) {
        if ($v.Contains("'") -or $v.Contains('"')) {
            throw "参数值不能包含引号(会导致计划任务命令损坏): $v"
        }
    }
    if ($Name -match '[\\/:*?"<>|]') {
        throw 'Name 含有计划任务名不允许的字符: \ / : * ? " < > |'
    }

    $taskName = if ($TaskName) { $TaskName } else { "$script:TaskPrefix$Name" }
    $driveDesc = if ($DriveLetter) { " -> ${DriveLetter}:" } else { ' -> 自动盘符' }
    if (-not $Description) {
        $Description = "登录时自动挂载 SSHFS 远程目录 ($Name$driveDesc)"
    }

    # 盘符留空时不传 -DriveLetter, 由计划任务执行时自动从 Z 往前找可用盘符; -Log 用于登录挂载失败的事后排查
    $driveArg = if ($DriveLetter) { " -DriveLetter '$DriveLetter'" } else { '' }
    $scriptBlock = "Import-Module SSHFSAutoMount; Mount-SSHFSDrive -Name '$Name'$driveArg -Label '$Label' -Log"
    $argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $scriptBlock + '"'

    $action   = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argument
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    # 默认 DisallowStartIfOnBatteries=true 会导致笔记本电池供电登录时任务不触发, 这里显式放行
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    if ($PSCmdlet.ShouldProcess($taskName, "注册登录自动挂载计划任务 ($scriptBlock)")) {
        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Description $Description -Force -ErrorAction Stop | Out-Null
        } catch {
            throw "注册计划任务失败: $($_.Exception.Message)"
        }

        try {
            return Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        } catch {
            throw "任务已注册但查询失败: $($_.Exception.Message)"
        }
    }
}

# ---------- 3. 查询计划任务 ----------
function Get-SSHFSAutoMount {
    <#
    .SYNOPSIS
    查询本模块注册的所有自动挂载计划任务(前缀 SSHFSAutoMount-)。

    .PARAMETER Name
    可选, 只查看某个 Host 对应的任务。

    .EXAMPLE
    Get-SSHFSAutoMount

    .EXAMPLE
    Get-SSHFSAutoMount home
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)

    $pattern = if ($Name) { "$script:TaskPrefix$Name" } else { "$script:TaskPrefix*" }
    $tasks = @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue)

    if ($tasks.Count -eq 0) {
        Write-Verbose "未找到匹配的计划任务: $pattern"
        return
    }

    foreach ($t in $tasks) {
        $hostName = $t.TaskName.Substring($script:TaskPrefix.Length)
        $action   = "$($t.Actions.Execute) $($t.Actions.Arguments)"
        $triggers = ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
        [pscustomobject]@{
            TaskName    = $t.TaskName
            Host        = $hostName
            State       = $t.State
            Trigger     = $triggers
            Action      = $action
            Description = $t.Description
        }
    }
}

# ---------- 4. 删除计划任务 ----------
function Unregister-SSHFSAutoMount {
    <#
    .SYNOPSIS
    删除自动挂载计划任务。

    .PARAMETER Name
    ssh config.d 中的 Host 别名(如 home)。

    .PARAMETER TaskName
    计划任务名, 默认 SSHFSAutoMount-<Name>。

    .EXAMPLE
    Unregister-SSHFSAutoMount home
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [string]$TaskName
    )

    $taskName = if ($TaskName) { $TaskName } else { "$script:TaskPrefix$Name" }

    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw "计划任务不存在: $taskName"
    }

    if ($PSCmdlet.ShouldProcess($taskName, '删除计划任务')) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Verbose "已删除计划任务: $taskName"
    }
}

Export-ModuleMember -Function Mount-SSHFSDrive, Register-SSHFSAutoMount, Get-SSHFSAutoMount, Unregister-SSHFSAutoMount

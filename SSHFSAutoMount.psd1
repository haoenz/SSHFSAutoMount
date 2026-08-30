@{
    RootModule        = 'SSHFSAutoMount.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'a7c4b1e2-9d3f-4c8b-8e5a-6f2d1c9b7e3a'
    Author            = 'yiyan'
    Description       = 'SSHFS-Win (sshfs.k) 远程目录自动挂载模块: 挂载 / 注册登录自动挂载计划任务 / 查询 / 删除'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Mount-SSHFSDrive',
        'Register-SSHFSAutoMount',
        'Get-SSHFSAutoMount',
        'Unregister-SSHFSAutoMount'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('sshfs', 'winfsp', 'mount', 'scheduled-task')
        }
    }
}

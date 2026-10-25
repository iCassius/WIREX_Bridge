[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiLifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$tokens, [ref]$parseErrors)
Assert-UiLifecycle ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$beginStopAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Begin-PreparationStop' }, $true)
$completeStopAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Complete-PreparationStop' }, $true)
Assert-UiLifecycle ($null -ne $beginStopAst -and $beginStopAst.Extent.Text.Contains('.BeginStop(')) '设备检查取消没有使用异步 BeginStop。'
Assert-UiLifecycle ($null -ne $completeStopAst -and $completeStopAst.Extent.Text.Contains('Environment]::Exit(2)')) '取消超时路径没有结束 UI 进程。'

$pipeline = [System.Management.Automation.PowerShell]::Create()
$stopResult = $null
try {
    [void]$pipeline.AddScript('while ($true) { Start-Sleep -Milliseconds 50 }')
    $invokeResult = $pipeline.BeginInvoke()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stopResult = $pipeline.BeginStop($null, $null)
    $timer.Stop()
    Assert-UiLifecycle ($timer.ElapsedMilliseconds -lt 500) 'BeginStop 同步等待了设备检查管线。'
    Assert-UiLifecycle ($stopResult.AsyncWaitHandle.WaitOne(5000)) '本地无 I/O 检查管线没有在 5 秒内取消。'
    $pipeline.EndStop($stopResult)
    Assert-UiLifecycle ($pipeline.InvocationStateInfo.State -ne [System.Management.Automation.PSInvocationState]::Running) '取消后的 PowerShell 管线仍在运行。'
} finally {
    if ($pipeline) { $pipeline.Dispose() }
}

Write-Output '通过：PS5.1 使用无 I/O stall fixture 异步取消设备预检，并在 5 秒内结束管线。'

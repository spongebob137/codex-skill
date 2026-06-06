param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Task,

    [string]$TaskFile,

    [ValidateSet("claude", "opencode")]
    [string]$Backend = "claude",

    [string]$ClaudePath,

    [string]$Model,

    [string]$Agent = "build",

    [ValidateSet("acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan")]
    [string]$PermissionMode = "auto",

    [string]$MaxBudgetUsd = $env:CLAUDE_WORKER_MAX_BUDGET_USD,

    [int]$TimeoutSec = 1800,

    [int]$IdleTimeoutSec = 300,

    [switch]$NoLiveOutput,

    [switch]$RawLiveOutput,

    [switch]$KeepWorktree
)

$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Convert-ToJsonDepth {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Write-ReportAndExit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Report,
        [Parameter(Mandatory = $true)][int]$Code
    )

    $Report.exit_code = $Code
    $json = Convert-ToJsonDepth -Value $Report

    if ($Report.report_path) {
        $reportDir = Split-Path -Parent $Report.report_path
        if ($reportDir) {
            New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
        }
        Set-Content -LiteralPath $Report.report_path -Value $json -Encoding UTF8
    }

    Write-Output $json
    exit $Code
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & git @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code ${code}: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-ChangedFiles {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)

    $status = & git -C $WorktreePath status --porcelain=v1 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $status) {
        return @()
    }

    $files = foreach ($line in $status) {
        if ($line.Length -ge 4) {
            $path = $line.Substring(3).Trim()
            if ($path -match " -> ") {
                $path = ($path -split " -> ")[-1]
            }
            $path
        }
    }

    return @($files | Sort-Object -Unique)
}

function Test-SensitivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = ($Path -replace "\\", "/")
    return $normalized -match "(?i)(^|/)(\.env(\..*)?|auth\.json|.*token.*|.*secret.*|.*credential.*|.*auths?/.*\.json|.*\.pem|.*\.key)$"
}

function Resolve-ClaudeCommand {
    param([string]$ExplicitPath)

    $candidates = @()
    if ($ExplicitPath) {
        $candidates += $ExplicitPath
    }

    if ($env:APPDATA) {
        $candidates += (Join-Path $env:APPDATA "npm/claude.cmd")
        $candidates += (Join-Path $env:APPDATA "npm/claude.exe")
        $candidates += (Join-Path $env:APPDATA "npm/claude")
    }

    $claudeCmd = Get-Command claude.cmd -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $candidates += $claudeCmd.Source
    }

    $claudeExe = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($claudeExe) {
        $candidates += $claudeExe.Source
    }

    foreach ($claude in @(Get-Command claude -All -ErrorAction SilentlyContinue)) {
        if ($claude.Source) {
            $candidates += $claude.Source
        }
    }

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $extension = [System.IO.Path]::GetExtension($candidate)
        if ($extension -in @(".ps1", ".psm1", ".psd1")) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Resolve-OpenCodeCommand {
    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencode) {
        return $opencode.Source
    }

    $opencodeCmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
    if ($opencodeCmd) {
        return $opencodeCmd.Source
    }

    return $null
}

function Invoke-QuickProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 20
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($arg in $Arguments) {
        [void]$startInfo.ArgumentList.Add($arg)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $process.Kill($true) } catch { }
    }

    $stdoutTask.Wait()
    $stderrTask.Wait()

    return @{
        exit_code = if ($timedOut) { 124 } else { $process.ExitCode }
        timed_out = $timedOut
        stdout = $stdoutTask.Result
        stderr = $stderrTask.Result
    }
}

function Invoke-WorkerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$IdleTimeoutSeconds,
        [string]$StandardInputText,
        [bool]$LiveOutput,
        [bool]$RawLiveOutput,
        [string]$Backend
    )

    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($arg in $Arguments) {
        [void]$startInfo.ArgumentList.Add($arg)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    [void]$process.Start()

    $stdoutFile = [System.IO.FileStream]::new($StdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stderrFile = [System.IO.FileStream]::new($StderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrFile)

    if ($null -ne $StandardInputText) {
        $process.StandardInput.Write($StandardInputText)
        $process.StandardInput.Close()
    }

    $script:claudeLiveBuffer = ""
    $script:opencodeWorkerLastEventSummary = ""
    $script:opencodeWorkerLastToolName = ""
    $script:opencodeWorkerLastToolTarget = ""

    function Limit-EventText {
        param([AllowNull()][string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return ""
        }

        $singleLine = ($Text -replace "\s+", " ").Trim()
        if ($singleLine.Length -le 500) {
            return $singleLine
        }

        return "$($singleLine.Substring(0, 497))..."
    }

    function Set-LastWorkerEvent {
        param(
            [Parameter(Mandatory = $true)][string]$Summary,
            [string]$ToolName = "",
            [string]$ToolTarget = ""
        )

        $script:opencodeWorkerLastEventSummary = Limit-EventText -Text $Summary
        if ($ToolName) {
            $script:opencodeWorkerLastToolName = $ToolName
        }
        if ($ToolTarget) {
            $script:opencodeWorkerLastToolTarget = Limit-EventText -Text $ToolTarget
        }
    }

    function Get-EventProperty {
        param(
            [AllowNull()]$Object,
            [Parameter(Mandatory = $true)][string]$Name
        )

        if ($null -eq $Object) {
            return $null
        }

        $property = $Object.PSObject.Properties[$Name]
        if ($property) {
            return $property.Value
        }

        return $null
    }

    function Write-ClaudeLiveLine {
        param([string]$Line)

        if ([string]::IsNullOrWhiteSpace($Line)) {
            return
        }

        try {
            $event = $Line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            [Console]::Out.WriteLine("[claude] $Line")
            Set-LastWorkerEvent -Summary "raw stdout: $Line"
            return
        }

        if ($event.type -eq "system" -and $event.subtype -eq "init") {
            [Console]::Out.WriteLine("[claude] started model=$($event.model) cwd=$($event.cwd)")
            Set-LastWorkerEvent -Summary "init model=$($event.model) cwd=$($event.cwd)"
            return
        }

        if ($event.type -eq "assistant" -and $event.message -and $event.message.content) {
            foreach ($item in @($event.message.content)) {
                if ($item.type -eq "text" -and $item.text) {
                    [Console]::Out.WriteLine("[claude] $($item.text)")
                    Set-LastWorkerEvent -Summary "assistant text: $($item.text)"
                } elseif ($item.type -eq "tool_use") {
                    $input = Get-EventProperty -Object $item -Name "input"
                    $filePath = Get-EventProperty -Object $input -Name "file_path"
                    $command = Get-EventProperty -Object $input -Name "command"
                    $target = ""
                    if ($filePath) {
                        $target = " $filePath"
                    } elseif ($command) {
                        $target = " $command"
                    }
                    [Console]::Out.WriteLine("[claude tool] $($item.name)$target")
                    Set-LastWorkerEvent -Summary "tool_use $($item.name)$target" -ToolName $item.name -ToolTarget $target
                }
            }
            return
        }

        $toolUseResult = Get-EventProperty -Object $event -Name "tool_use_result"
        if ($event.type -eq "user" -and $toolUseResult) {
            $resultType = Get-EventProperty -Object $toolUseResult -Name "type"
            $filePath = Get-EventProperty -Object $toolUseResult -Name "filePath"
            if (-not $filePath) {
                $file = Get-EventProperty -Object $toolUseResult -Name "file"
                $filePath = Get-EventProperty -Object $file -Name "filePath"
            }

            $stdout = Get-EventProperty -Object $toolUseResult -Name "stdout"
            if ($filePath) {
                [Console]::Out.WriteLine("[claude tool-result] $resultType $filePath")
                Set-LastWorkerEvent -Summary "tool_result $resultType $filePath"
            } elseif ($stdout) {
                [Console]::Out.WriteLine("[claude tool-result] stdout")
                Set-LastWorkerEvent -Summary "tool_result stdout: $stdout"
            } elseif ($resultType) {
                [Console]::Out.WriteLine("[claude tool-result] $resultType")
                Set-LastWorkerEvent -Summary "tool_result $resultType"
            }
            return
        }

        if ($event.type -eq "result") {
            $costValue = Get-EventProperty -Object $event -Name "total_cost_usd"
            $resultText = Get-EventProperty -Object $event -Name "result"
            $subtype = Get-EventProperty -Object $event -Name "subtype"
            $cost = if ($null -ne $costValue) { " cost=$costValue" } else { "" }
            $summary = if ($resultText) { " $resultText" } else { "" }
            [Console]::Out.WriteLine("[claude result] $subtype$cost$summary")
            Set-LastWorkerEvent -Summary "result $subtype$cost$summary"
        }
    }

    function Write-LiveChunk {
        param(
            [Parameter(Mandatory = $true)][string]$Chunk,
            [Parameter(Mandatory = $true)][bool]$IsError
        )

        if (-not $LiveOutput -or $Chunk.Length -eq 0) {
            return
        }

        if ($IsError) {
            [Console]::Error.Write($Chunk)
            Set-LastWorkerEvent -Summary "stderr: $Chunk"
            return
        }

        if ($Backend -ne "claude" -or $RawLiveOutput) {
            [Console]::Out.Write($Chunk)
            return
        }

        $script:claudeLiveBuffer = $script:claudeLiveBuffer + $Chunk
        while ($script:claudeLiveBuffer -match "(`r`n|`n)") {
            $newlineIndex = $script:claudeLiveBuffer.IndexOf("`n")
            $line = $script:claudeLiveBuffer.Substring(0, $newlineIndex).TrimEnd("`r")
            $script:claudeLiveBuffer = $script:claudeLiveBuffer.Substring($newlineIndex + 1)
            Write-ClaudeLiveLine -Line $line
        }
    }

    function Read-NewFileChunk {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][ref]$Position,
            [Parameter(Mandatory = $true)][bool]$IsError
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $readerStream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($readerStream.Length -le $Position.Value) {
                $Position.Value = $readerStream.Length
                return $false
            }

            [void]$readerStream.Seek([int64]$Position.Value, [System.IO.SeekOrigin]::Begin)
            $reader = [System.IO.StreamReader]::new($readerStream, $utf8NoBom, $true, 4096, $true)
            try {
                $chunk = $reader.ReadToEnd()
                $Position.Value = $readerStream.Position
                Write-LiveChunk -Chunk $chunk -IsError $IsError
                return ($chunk.Length -gt 0)
            } finally {
                $reader.Dispose()
            }
        } finally {
            $readerStream.Dispose()
        }
    }

    [int64]$stdoutPosition = 0
    [int64]$stderrPosition = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastOutputAt = Get-Date
    $lastStdoutAt = $null
    $lastStderrAt = $null
    $timedOut = $false
    $idleTimedOut = $false

    while (-not $process.HasExited) {
        $stdoutChanged = Read-NewFileChunk -Path $StdoutPath -Position ([ref]$stdoutPosition) -IsError $false
        if ($stdoutChanged) {
            $lastOutputAt = Get-Date
            $lastStdoutAt = $lastOutputAt
        }

        $stderrChanged = Read-NewFileChunk -Path $StderrPath -Position ([ref]$stderrPosition) -IsError $true
        if ($stderrChanged) {
            $lastOutputAt = Get-Date
            $lastStderrAt = $lastOutputAt
        }

        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            break
        }

        if ($IdleTimeoutSeconds -gt 0 -and ((Get-Date) - $lastOutputAt).TotalSeconds -ge $IdleTimeoutSeconds) {
            $idleTimedOut = $true
            try { $process.Kill($true) } catch { }
            break
        }

        Start-Sleep -Milliseconds 200
    }

    $process.WaitForExit()
    $stdoutCopy.Wait()
    $stderrCopy.Wait()
    $stdoutFile.Dispose()
    $stderrFile.Dispose()

    $stdoutChanged = Read-NewFileChunk -Path $StdoutPath -Position ([ref]$stdoutPosition) -IsError $false
    if ($stdoutChanged) {
        $lastOutputAt = Get-Date
        $lastStdoutAt = $lastOutputAt
    }

    $stderrChanged = Read-NewFileChunk -Path $StderrPath -Position ([ref]$stderrPosition) -IsError $true
    if ($stderrChanged) {
        $lastOutputAt = Get-Date
        $lastStderrAt = $lastOutputAt
    }
    if ($LiveOutput -and $Backend -eq "claude" -and -not $RawLiveOutput -and $script:claudeLiveBuffer) {
        Write-ClaudeLiveLine -Line $script:claudeLiveBuffer
        $script:claudeLiveBuffer = ""
    }

    return @{
        exit_code = if ($timedOut -or $idleTimedOut) { 124 } else { $process.ExitCode }
        timed_out = $timedOut
        idle_timed_out = $idleTimedOut
        last_output_at = $lastOutputAt.ToString("o")
        last_stdout_at = if ($lastStdoutAt) { $lastStdoutAt.ToString("o") } else { $null }
        last_stderr_at = if ($lastStderrAt) { $lastStderrAt.ToString("o") } else { $null }
        last_event_summary = $script:opencodeWorkerLastEventSummary
        last_tool_name = $script:opencodeWorkerLastToolName
        last_tool_target = $script:opencodeWorkerLastToolTarget
    }
}

if (-not $Model -or [string]::IsNullOrWhiteSpace($Model)) {
    if ($Backend -eq "claude") {
        $Model = if ($env:CLAUDE_WORKER_MODEL) { $env:CLAUDE_WORKER_MODEL } else { "sonnet" }
    } else {
        $Model = $env:OPENCODE_WORKER_MODEL
    }
}

$claudeBudget = $null
if ($Backend -eq "claude" -and $MaxBudgetUsd -and -not [string]::IsNullOrWhiteSpace($MaxBudgetUsd)) {
    $claudeBudget = $MaxBudgetUsd.Trim()
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$runId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$branch = "worker/$Backend/$runId"
$baseDir = Join-Path $codexHome "tmp/opencode-worker"
$runDir = Join-Path $baseDir "runs/$runId"
$worktree = Join-Path $baseDir "worktrees/$runId"
$stdoutPath = Join-Path $runDir "$Backend.stdout.log"
$stderrPath = Join-Path $runDir "$Backend.stderr.log"
$taskPath = Join-Path $runDir "task.md"
$reportPath = Join-Path $runDir "report.json"
$liveOutput = -not $NoLiveOutput.IsPresent

New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$report = @{
    run_id = $runId
    backend = $Backend
    branch = $branch
    worktree = $worktree
    exit_code = $null
    worker_exit_code = $null
    opencode_exit_code = $null
    model = $Model
    permission_mode = if ($Backend -eq "claude") { $PermissionMode } else { $null }
    max_budget_usd = if ($Backend -eq "claude") { $claudeBudget } else { $null }
    idle_timeout_sec = $IdleTimeoutSec
    live_output = $liveOutput
    raw_live_output = $RawLiveOutput.IsPresent
    worker_command = @()
    changed_files = @()
    sensitive_changed_files = @()
    status_porcelain = @()
    diff_stat = ""
    status = "starting"
    message = ""
    log_path = $stdoutPath
    stderr_path = $stderrPath
    task_path = $taskPath
    report_path = $reportPath
    claude_version = $null
    claude_auth_status = $null
    last_output_at = $null
    last_stdout_at = $null
    last_stderr_at = $null
    last_event_summary = ""
    last_tool_name = ""
    last_tool_target = ""
}

try {
    if (($Task -and $TaskFile) -or (-not $Task -and -not $TaskFile)) {
        $report.status = "invalid_arguments"
        $report.message = "Provide exactly one of -Task or -TaskFile."
        Write-ReportAndExit -Report $report -Code 2
    }

    if (-not $Model -or [string]::IsNullOrWhiteSpace($Model)) {
        $report.status = "missing_model"
        $report.message = "Set -Model or the backend model environment variable before running."
        Write-ReportAndExit -Report $report -Code 2
    }

    $repoPath = (Resolve-Path -LiteralPath $Repo).Path
    $gitRootOutput = @(Invoke-Git -Arguments @("-C", $repoPath, "rev-parse", "--show-toplevel"))
    $gitRoot = (Resolve-Path -LiteralPath $gitRootOutput[0]).Path

    $dirty = & git -C $gitRoot status --porcelain=v1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect git status for $gitRoot."
    }
    if ($dirty) {
        $report.status = "dirty_repo"
        $report.message = "The source worktree has uncommitted changes. Commit, stash, or clean them before delegating to a worker CLI."
        Write-ReportAndExit -Report $report -Code 3
    }

    if ($TaskFile) {
        $taskContent = Get-Content -Raw -LiteralPath $TaskFile -Encoding UTF8
    } else {
        $taskContent = $Task
    }

    $workerBrief = @"
# Worker task

You are a local implementation worker supervised by Codex.

Repository: $gitRoot
Working directory: $worktree
Branch: $branch
Backend: $Backend

Rules:
- Keep the change narrowly scoped to the task.
- Prefer existing project patterns.
- Do not edit secrets, credentials, auth tokens, .env files, or unrelated generated artifacts.
- Run only relevant verification commands.
- Treat verification failures as evidence to report. Do not reclassify failed commands as acceptable warnings unless the task explicitly asks for that documentation change.
- If you hit a tooling, budget, permission, or environment problem, stop after capturing the useful artifact and summarize what Codex should inspect or improve.
- Leave a concise final summary with changed files and verification results.
- Do not merge, commit, push, install global tools, or change system configuration.

Task:
$taskContent
"@

    Set-Content -LiteralPath $taskPath -Value $workerBrief -Encoding UTF8

    $workerCommand = $null
    $workerArgs = @()
    $stdinText = $null

    if ($Backend -eq "claude") {
        $workerCommand = Resolve-ClaudeCommand -ExplicitPath $ClaudePath
        if (-not $workerCommand) {
            $report.status = "missing_claude"
            $report.message = "claude was not found. Checked PATH and $env:APPDATA/npm/claude.cmd. Pass -ClaudePath if it is installed elsewhere."
            Write-ReportAndExit -Report $report -Code 127
        }

        $versionResult = Invoke-QuickProcess -FilePath $workerCommand -Arguments @("--version") -WorkingDirectory $gitRoot -TimeoutSeconds 20
        $report.claude_version = ($versionResult.stdout + $versionResult.stderr).Trim()
        if ($versionResult.exit_code -ne 0) {
            $report.status = "claude_version_failed"
            $report.message = "Claude Code was found but --version failed: $($report.claude_version)"
            Write-ReportAndExit -Report $report -Code $versionResult.exit_code
        }

        $authResult = Invoke-QuickProcess -FilePath $workerCommand -Arguments @("auth", "status") -WorkingDirectory $gitRoot -TimeoutSeconds 20
        $report.claude_auth_status = ($authResult.stdout + $authResult.stderr).Trim()
        if ($authResult.exit_code -ne 0) {
            $report.status = "claude_auth_failed"
            $report.message = "Claude Code auth status failed. Run claude auth status in a trusted terminal."
            Write-ReportAndExit -Report $report -Code $authResult.exit_code
        }

        $workerArgs = @(
            "-p",
            "--input-format", "text",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", $PermissionMode,
            "--model", $Model,
            "--no-session-persistence"
        )
        if ($claudeBudget) {
            $workerArgs += @("--max-budget-usd", $claudeBudget)
        }
        $stdinText = $workerBrief
    } else {
        $workerCommand = Resolve-OpenCodeCommand
        if (-not $workerCommand) {
            $report.status = "missing_opencode"
            $report.message = "opencode was not found on PATH. Install and configure OpenCode first; this helper will not install global tools automatically."
            Write-ReportAndExit -Report $report -Code 127
        }

        if (-not $Model -or [string]::IsNullOrWhiteSpace($Model)) {
            $report.status = "missing_model"
            $report.message = "Set -Model or OPENCODE_WORKER_MODEL before running OpenCode, so it does not fall back to an expensive default model."
            Write-ReportAndExit -Report $report -Code 2
        }

        $workerArgs = @(
            "run",
            "--dir", $worktree,
            "--agent", $Agent,
            "--model", $Model,
            "--file", $taskPath,
            "--format", "json"
        )
    }

    $report.worker_command = @($workerCommand) + $workerArgs

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $worktree) | Out-Null
    Invoke-Git -Arguments @("-C", $gitRoot, "worktree", "add", "-b", $branch, $worktree, "HEAD") | Out-Null

    $processResult = Invoke-WorkerProcess -FilePath $workerCommand -Arguments $workerArgs -WorkingDirectory $worktree -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSec -IdleTimeoutSeconds $IdleTimeoutSec -StandardInputText $stdinText -LiveOutput $liveOutput -RawLiveOutput $RawLiveOutput.IsPresent -Backend $Backend
    $report.worker_exit_code = $processResult.exit_code
    $report.last_output_at = $processResult.last_output_at
    $report.last_stdout_at = $processResult.last_stdout_at
    $report.last_stderr_at = $processResult.last_stderr_at
    $report.last_event_summary = $processResult.last_event_summary
    $report.last_tool_name = $processResult.last_tool_name
    $report.last_tool_target = $processResult.last_tool_target
    if ($Backend -eq "opencode") {
        $report.opencode_exit_code = $processResult.exit_code
    }

    $report.status_porcelain = @(& git -C $worktree status --porcelain=v1 2>$null)
    $report.changed_files = @(Get-ChangedFiles -WorktreePath $worktree)
    $report.diff_stat = ((& git -C $worktree diff --stat -- 2>$null) -join [Environment]::NewLine)
    if (-not $report.diff_stat -and $report.status_porcelain.Count -gt 0) {
        $report.diff_stat = ($report.status_porcelain -join [Environment]::NewLine)
    }
    $report.sensitive_changed_files = @($report.changed_files | Where-Object { Test-SensitivePath -Path $_ })

    if ($processResult.idle_timed_out) {
        $report.status = "idle_timeout"
        $report.message = "$Backend produced no output for $IdleTimeoutSec seconds."
        Write-ReportAndExit -Report $report -Code 124
    }

    if ($processResult.timed_out) {
        $report.status = "timeout"
        $report.message = "$Backend timed out after $TimeoutSec seconds."
        Write-ReportAndExit -Report $report -Code 124
    }

    if ($report.sensitive_changed_files.Count -gt 0) {
        $report.status = "blocked_sensitive_changes"
        $report.message = "$Backend changed sensitive-looking files. Review manually; the worktree has been preserved."
        Write-ReportAndExit -Report $report -Code 4
    }

    if ($processResult.exit_code -ne 0) {
        $report.status = "${Backend}_failed"
        $report.message = "$Backend exited nonzero. Treat output as a draft and inspect logs before using it."
        if (-not $KeepWorktree -and $report.changed_files.Count -eq 0) {
            & git -C $gitRoot worktree remove --force $worktree 2>$null | Out-Null
        }
        Write-ReportAndExit -Report $report -Code $processResult.exit_code
    }

    if ($report.changed_files.Count -eq 0) {
        $report.status = "no_changes"
        $report.message = "$Backend completed but produced no file changes."
        if (-not $KeepWorktree) {
            & git -C $gitRoot worktree remove --force $worktree 2>$null | Out-Null
        }
        Write-ReportAndExit -Report $report -Code 0
    }

    $report.status = "completed_with_changes"
    $report.message = "$Backend completed with changes in the isolated worktree. Review before applying or merging."
    Write-ReportAndExit -Report $report -Code 0
} catch {
    $report.status = "script_error"
    $report.message = $_.Exception.Message
    Write-ReportAndExit -Report $report -Code 1
}

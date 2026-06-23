$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\FFUOrchestrationBootstrap.log'
Start-Transcript -Path $logPath -Append -Force | Out-Null

try {
    Write-Host 'Starting FFU orchestration bootstrap.'
    $deadline = (Get-Date).AddMinutes(10)
    $orchestratorPath = $null

    do {
        $fileSystemDrives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Root) })
        foreach ($driveInfo in $fileSystemDrives) {
            $candidatePath = Join-Path -Path $driveInfo.Root -ChildPath 'Orchestration\Orchestrator.ps1'
            Write-Host "Checking for orchestrator at $candidatePath"
            if (Test-Path -Path $candidatePath -PathType Leaf) {
                $orchestratorPath = $candidatePath
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($orchestratorPath)) {
            break
        }

        Write-Host 'Apps ISO orchestrator was not found yet. Waiting before retry.'
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    if ([string]::IsNullOrWhiteSpace($orchestratorPath)) {
        throw 'Unable to locate Apps ISO orchestrator after waiting for Apps media.'
    }

    $env:FFUAppsRoot = Split-Path -Parent (Split-Path -Parent $orchestratorPath)
    Write-Host "Using Apps media root: $env:FFUAppsRoot"
    Write-Host "Launching orchestrator: $orchestratorPath"
    & $orchestratorPath
    Write-Host 'FFU orchestrator completed.'
}
catch {
    Write-Error "FFU orchestration bootstrap failed: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
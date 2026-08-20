# Run disk cleanup (cleanmgr.exe) with all options enabled
# Reference: https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/automating-disk-cleanup-tool

$rootKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"

$timeoutMinutes = 30
$pumpIntervalSeconds = 5
$wmNull = 0x0000

if (-not ("DiskCleanup.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @'
namespace DiskCleanup
{
    public static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "PostThreadMessageW", SetLastError = true)]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        public static extern bool PostThreadMessage(
            uint idThread,
            uint Msg,
            System.UIntPtr wParam,
            System.IntPtr lParam
        );
    }
}
'@
}

try {
    # Set StateFlags0000 to 2 for all subkeys except "Offline Pages Files"
    Get-ChildItem -Path $rootKey | ForEach-Object {
        if ($_.PSChildName -ne "Offline Pages Files") {
            Set-ItemProperty -Path $_.PSPath -Name "StateFlags0000" -Type DWord -Value 2 -Force
        }
    }

    # Run the disk cleanup tool with the specified flags.
    # Do not use Start-Process -Wait here; cleanmgr.exe can hang waiting for its own UI message thread.
    $cleanMgrPath = Join-Path $env:SystemRoot "System32\cleanmgr.exe"

    $process = Start-Process -FilePath $cleanMgrPath `
        -ArgumentList "/sagerun:0" `
        -WindowStyle Normal `
        -PassThru

    $deadline = (Get-Date).AddMinutes($timeoutMinutes)

Write-Host "Started cleanmgr.exe. PID: $($process.Id)"
Write-Host "Posting WM_NULL to cleanmgr.exe threads every $pumpIntervalSeconds seconds while waiting for exit."

$pumpCount = 0

while (-not $process.HasExited) {
    if ((Get-Date) -ge $deadline) {
        throw "cleanmgr.exe did not exit within $timeoutMinutes minutes. PID: $($process.Id)"
    }

    Start-Sleep -Seconds $pumpIntervalSeconds

    try {
        $liveProcess = Get-Process -Id $process.Id -ErrorAction Stop

        $pumpCount++
        $postedCount = 0
        $failedCount = 0
        $threadIdsPosted = New-Object System.Collections.Generic.List[int]

        foreach ($thread in $liveProcess.Threads) {
            # Wake threads blocked in GetMessageW, such as cleanmgr!PurgeAbortThread.
            # Failures are expected for threads that do not have message queues.
            $posted = [DiskCleanup.NativeMethods]::PostThreadMessage(
                [uint32]$thread.Id,
                [uint32]$wmNull,
                [System.UIntPtr]::Zero,
                [System.IntPtr]::Zero
            )

            if ($posted) {
                $postedCount++
                $threadIdsPosted.Add([int]$thread.Id)
            }
            else {
                $failedCount++
            }
        }

        $elapsed = New-TimeSpan -Start $process.StartTime -End (Get-Date)

        Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] cleanmgr.exe still running. Pump #{1}. Posted WM_NULL to {2}/{3} threads. Successful TIDs: {4}. Elapsed: {5:n1}s" -f `
            (Get-Date),
            $pumpCount,
            $postedCount,
            $liveProcess.Threads.Count,
            ($(if ($threadIdsPosted.Count -gt 0) { ($threadIdsPosted -join ',') } else { 'none' })),
            $elapsed.TotalSeconds
        )

        $process.Refresh()
    }
    catch [System.ArgumentException] {
        # Process exited between checks.
        break
    }
    catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        # Process exited between checks.
        break
    }
}

$process.Refresh()

if ($process.HasExited) {
    Write-Host "cleanmgr.exe exited. ExitCode: $($process.ExitCode)"
}

    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw "cleanmgr.exe exited with code $($process.ExitCode)."
    }
}
finally {
    # Remove the StateFlags0000 registry values that were added
    Get-ChildItem -Path $rootKey | ForEach-Object {
        if ($_.PSChildName -ne "Offline Pages Files") {
            Remove-ItemProperty -Path $_.PSPath -Name "StateFlags0000" -Force -ErrorAction SilentlyContinue
        }
    }
}
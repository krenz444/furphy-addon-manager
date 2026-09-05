param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$server = $null
try {
    $server = Start-TestServer -Root $AppRoot -Port 47899 -WowRoot $WowRoot -IdleMinutes 60 -ScriptPath (Join-Path $AppRoot 'addon-server.ps1')
    Write-Host "Server up, pid=$($server.Process.Id)"

    # -Force so this real sync actually re-downloads/reinstalls both
    # already-up-to-date addons instead of a near-instant no-op check -
    # a representative "sync job running" window, not "job started and
    # immediately finished".
    $post = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'sync'; force = $true }
    if (-not $post.Ok) { throw "POST /api/jobs failed: $($post.StatusCode) $($post.Body | ConvertTo-Json -Compress)" }
    $jobId = $post.Body.jobId
    Write-Host "Job posted: $jobId"

    # Measure for up to 45s (BigWigs+LittleWigs real re-download is
    # comfortably done well inside that on a normal connection); poll
    # job status in parallel so we can report how long it actually took.
    $measureJob = Start-Job -ScriptBlock {
        param($ScriptDir, $LogPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Measure-Furphy.ps1') `
            -Label 'F-sync-job-no-wow' -DurationSec 45 `
            -ServerLogPath $LogPath `
            -Notes 'State F: a real sync job (kind=sync, force=true, retail: BigWigs+LittleWigs) running via POST /api/jobs, no WoW running.'
    } -ArgumentList $PSScriptRoot, (Join-Path $AppRoot 'server.log')

    $deadline = (Get-Date).AddSeconds(60)
    $lastState = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $st = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$jobId`?flavour=retail"
        if ($st.Ok) { $lastState = $st.Body.state }
        if ($lastState -eq 'done' -or $lastState -eq 'error') { break }
    }
    Write-Host "Job final state: $lastState"

    Receive-Job -Job $measureJob -Wait -AutoRemoveJob | Write-Host
} finally {
    Stop-TestServer -Server $server
}

# snap-watch.ps1  (v2)
# Change-detection snapshots for storage01 + client01 (VirtualBox lab).
# Runs every 5 min via Task Scheduler:
#   1. SSH into each running VM, get hashes of watched config paths.
#   2. If any hash changed -> remember what and when.
#   3. If no new changes for $IdleMin minutes -> pause both VMs, snapshot both, resume.
#   4. Keep only the last $KeepAuto auto_ snapshots per VM.
#
# Usage:
#   .\snap-watch.ps1            normal run (what Task Scheduler does)
#   .\snap-watch.ps1 -Verbose   same, but also prints the log to the screen
#   .\snap-watch.ps1 -DryRun    show what would happen; changes nothing
#   .\snap-watch.ps1 -Force     take a snapshot now (named manual_..., not auto-deleted)
#   .\snap-watch.ps1 -h         help
#
# Exit codes: 0 = ok, 1 = errors (see log). Task Scheduler shows it as Last Run Result.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun,
    [Alias('h')][switch]$Help
)

$VBox      = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$IdleMin   = 15
$KeepAuto  = 10
$WorkDir   = "$env:USERPROFILE\Desktop\Projects\Linux Sandbox Storage\snap-watch"
$StateFile = Join-Path $WorkDir "state.json"
$LogFile   = Join-Path $WorkDir "snap-watch.log"
$LockFile  = Join-Path $WorkDir "snap-watch.lock"

$VMs = [ordered]@{
    "storage01" = @{
        Ssh    = "user_name@127.0.0.1"
        Port   = 2222
        Paths  = @(
            "/etc/target",
            "/etc/lvm/backup",
            "/etc/firewalld/zones",
            "/etc/NetworkManager/system-connections",
            "/etc/exports",
            "/etc/exports.d",
            "/etc/fstab"
        )
        Images = "/var/lib/sandbox-disks"
    }
    "client01" = @{
        Ssh    = "user_name@127.0.0.1"
        Port   = 2223
        Paths  = @(
            "/etc/iscsi",
            "/var/lib/iscsi",
            "/etc/multipath",
            "/etc/multipath.conf",
            "/etc/lvm/backup",
            "/etc/NetworkManager/system-connections",
            "/etc/fstab"
        )
        Images = $null
    }
}

if ($Help) {
    $me = Split-Path -Leaf $PSCommandPath
    Write-Host @"
$me - snapshots of storage01 + client01 after config changes

Usage:
  .\$me            normal run (what Task Scheduler does)
  .\$me -Verbose   normal run + log on screen
  .\$me -DryRun    show what would happen; changes nothing
  .\$me -Force     take a snapshot now (manual_..., never auto-deleted)
  .\$me -h         this help

Files:
  log    $LogFile
  state  $StateFile

Exit codes: 0 = ok, 1 = errors (see log)
"@
    exit 0
}

$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$exitCode = 0

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    if ($DryRun) { Write-Host "[dry-run] $line"; return }
    Add-Content -Path $LogFile -Value $line
    Write-Verbose $line
}

function Step($pct, $status) {
    Write-Progress -Activity "snap-watch" -Status $status -PercentComplete $pct
}

function Test-Running($vm) {
    $info = & $VBox showvminfo $vm --machinereadable 2>&1
    return [bool]($info | Where-Object { "$_" -eq 'VMState="running"' })
}

function Build-Remote($cfg) {
    $list = ($cfg.Paths | ForEach-Object { "'$_'" }) -join ' '
    if ($cfg.Images) { $list += " --meta '$($cfg.Images)'" }
    return "sudo -n /usr/local/bin/snapwatch-hash $list"
}

function Get-Hashes($vm, $cfg) {
    $remote = Build-Remote $cfg
    if ([string]::IsNullOrWhiteSpace($remote)) { throw "${vm}: empty remote command (check Build-Remote)" }

    $raw = & ssh.exe -n -p $cfg.Port `
        -o BatchMode=yes -o ConnectTimeout=5 `
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 `
        $cfg.Ssh $remote 2>&1
    $code = $LASTEXITCODE

    $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

    if ($code -ne 0) { throw "${vm}: ssh failed (exit $code): $($stderr -join ' | ')" }
    if ($stderr.Count -gt 0) { Log "WARN ${vm}: ssh stderr: $($stderr -join ' | ')" }

    $h = [ordered]@{}
    $bad = @()
    foreach ($line in $stdout) {
        $s = "$line".Trim()
        if (-not $s) { continue }
        if ($s -match '^(.+) ([0-9a-f]{12})$') { $h[$Matches[1]] = $Matches[2] }
        else { $bad += $s }
    }
    if ($bad.Count -gt 0) { throw "${vm}: unexpected output: $($bad -join ' | ')" }

    $expected = $cfg.Paths.Count + 1 + [int][bool]$cfg.Images
    if ($h.Count -ne $expected) { throw "${vm}: expected $expected items, got $($h.Count)" }
    return $h
}

function Get-ShortHash($text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    return ([BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 7).ToLower()
}

function Remove-OldAuto($vm) {
    $list = & $VBox snapshot $vm list --machinereadable 2>&1
    $names = @($list | ForEach-Object {
        if ("$_" -match '^SnapshotName[-\d]*="(auto_[^"]+)"') { $Matches[1] }
    } | Sort-Object)
    $excess = $names.Count - $KeepAuto
    for ($i = 0; $i -lt $excess; $i++) {
        & $VBox snapshot $vm delete $names[$i] 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "retention: deleted $vm $($names[$i])" }
        else { Log "ERROR retention: could not delete $vm $($names[$i])"; $script:exitCode = 1 }
    }
}

function New-PairSnapshot($name, $desc) {
    $ok = $true
    $paused = @()
    $running = @($VMs.Keys | Where-Object { Test-Running $_ })
    try {
        Step 70 "pausing VMs"
        foreach ($vm in $running) {
            $o = & $VBox controlvm $vm pause 2>&1
            if ($LASTEXITCODE -ne 0) { throw "pause $vm failed: $o" }
            $paused += $vm
        }
        foreach ($vm in $VMs.Keys) {
            Step 80 "$vm - taking snapshot $name"
            $o = & $VBox snapshot $vm take $name --description $desc 2>&1
            if ($LASTEXITCODE -eq 0) { Log "snapshot $vm -> $name" }
            else { Log "ERROR snapshot $vm failed: $o"; $ok = $false }
        }
    }
    catch {
        Log "ERROR $_"
        $ok = $false
    }
    finally {
        if ($paused.Count) { Step 90 "resuming VMs" }
        foreach ($vm in $paused) {
            & $VBox controlvm $vm resume 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "ERROR resume $vm failed - resume it manually in VirtualBox!"; $ok = $false }
        }
    }
    Step 95 "retention: cleaning old auto_ snapshots"
    foreach ($vm in $VMs.Keys) { Remove-OldAuto $vm }
    return $ok
}

try {
    $lock = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
}
catch {
    Log "another instance is running - exit"
    exit 0
}

try {
    $prev = @{}
    $pending = @()
    $lastChange = $null
    $lastSnap = ""
    if (Test-Path $StateFile) {
        $s = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($s.Hashes) { foreach ($p in $s.Hashes.PSObject.Properties) { $prev[$p.Name] = $p.Value } }
        if ($s.Pending) { $pending = @($s.Pending) }
        if ($s.LastChange) { $lastChange = [datetime]$s.LastChange }
        if ($s.LastSnapshot) { $lastSnap = $s.LastSnapshot }
    }

    $cur = @{}
    $failed = @()
    $n = $VMs.Count
    $i = 0
    foreach ($vm in $VMs.Keys) {
        $base = [int](60 * $i / $n); $i++
        Step $base "$vm - checking VM state"
        if (-not (Test-Running $vm)) { Log "$vm not running - skipped"; continue }
        try {
            Step ($base + [int](30 / $n)) "$vm - hashing config over SSH"
            $h = Get-Hashes $vm $VMs[$vm]
            foreach ($k in $h.Keys) { $cur["$vm|$k"] = $h[$k] }
        }
        catch {
            Log "ERROR $_"
            $failed += $vm
            $exitCode = 1
        }
    }

    $all = @{}
    foreach ($k in $prev.Keys) { $all[$k] = $prev[$k] }
    foreach ($k in $cur.Keys)  { $all[$k] = $cur[$k] }

    Step 65 "comparing with previous run"
    $now = Get-Date
    $changed = @($cur.Keys | Where-Object { $prev.ContainsKey($_) -and $prev[$_] -ne $cur[$_] })
    $baselineMissing = ($prev.Count -eq 0)

    if ($baselineMissing) {
        if ($failed.Count -gt 0 -or $cur.Count -eq 0) {
            Log "baseline NOT saved: no data from $(($failed + @()) -join ', ')"
            $all = @{}
        }
        else {
            Log "baseline saved ($($cur.Count) items)"
        }
    }
    elseif ($changed.Count -gt 0) {
        $lastChange = $now
        foreach ($c in $changed) { if ($pending -notcontains $c) { $pending += $c } }
        Log ("change detected: " + ($changed -join ', ') + " -> waiting $IdleMin min idle")
    }

    $idleOk = (-not $baselineMissing) -and $changed.Count -eq 0 -and $pending.Count -gt 0 -and
              $lastChange -and ($now - $lastChange).TotalMinutes -ge $IdleMin
    $doSnap = $Force -or $idleOk

    if ($doSnap -and $failed.Count -gt 0) {
        Log "snapshot postponed: state unknown for $($failed -join ', ')"
        $doSnap = $false
    }

    if ($doSnap) {
        $prefix   = $(if ($Force) { "manual" } else { "auto" })
        $joined   = ($all.Keys | Sort-Object | ForEach-Object { "$_=$($all[$_])" }) -join "`n"
        $snapName = "{0}_{1}_{2}" -f $prefix, $now.ToString("yyyy-MM-dd_HH-mm"), (Get-ShortHash $joined)

        $descLines = @($(if ($Force) { "Forced snapshot (-Force)" } else { "Auto snapshot after $IdleMin min idle" }))
        foreach ($vm in $VMs.Keys) {
            $items = @($pending | Where-Object { $_ -like "$vm|*" } | ForEach-Object { $_.Split('|', 2)[1] })
            if ($items.Count -gt 0) { $descLines += "$vm changed: " + ($items -join ', ') }
        }
        if ($lastSnap) { $descLines += "Previous: $lastSnap" }
        $desc = $descLines -join "`n"

        if ($DryRun) {
            Log "would take snapshot $snapName"
            Log "description: $($descLines -join ' / ')"
        }
        else {
            if (New-PairSnapshot $snapName $desc) {
                $lastSnap = $snapName
                $pending = @()
                $lastChange = $null
            }
            else {
                $exitCode = 1
            }
        }
    }
    elseif ($pending.Count -gt 0 -and $lastChange -and -not $DryRun) {
        $left = [math]::Ceiling($IdleMin - ($now - $lastChange).TotalMinutes)
        if ($left -gt 0) { Write-Verbose "pending: $($pending -join ', ') - snapshot in ~$left min if no new changes" }
    }

    if (-not $DryRun) {
        $state = @{
            Hashes       = $all
            Pending      = @($pending)
            LastChange   = $(if ($lastChange) { $lastChange.ToString("o") } else { $null })
            LastSnapshot = $lastSnap
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    }
}
catch {
    Log "ERROR unexpected: $_"
    $exitCode = 1
}
finally {
    Write-Progress -Activity "snap-watch" -Completed
    $lock.Close()
}

exit $exitCode

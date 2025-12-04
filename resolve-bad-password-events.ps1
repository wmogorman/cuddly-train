$sourceId = 'BadPasswordWatcher'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Subscribe to Security 4625 events (failed logons) in real time
$query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery(
    'Security',
    [System.Diagnostics.Eventing.Reader.PathType]::LogName,
    '*[System/EventID=4625]'
)

$watcher = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($query, $null, $true)

Write-Host "Monitoring for 0xC000006A failed logons... Press Ctrl+C to stop." -ForegroundColor Cyan
if (-not (Test-IsAdmin)) {
    Write-Warning "Reading the Security log requires elevation or the 'Manage auditing and security log' right. Run PowerShell as Administrator."
}

Register-ObjectEvent -InputObject $watcher -EventName EventRecordWritten -SourceIdentifier $sourceId -Action {
    $record = $Event.SourceEventArgs.EventRecord
    if (-not $record) { return }

    # Parse the event XML for detailed fields
    $xml  = [xml]$record.ToXml()
    $data = $xml.Event.EventData.Data

    $status    = ($data | Where-Object Name -eq 'Status').'#text'
    $subStatus = ($data | Where-Object Name -eq 'SubStatus').'#text'

    # Only act on bad password events
    if ($status -ne '0xC000006A' -and $subStatus -ne '0xC000006A') { return }

    $username    = ($data | Where-Object Name -eq 'TargetUserName').'#text'
    $procIdHex   = ($data | Where-Object Name -eq 'ProcessId').'#text'
    $procName    = ($data | Where-Object Name -eq 'ProcessName').'#text'
    $ipAddress   = ($data | Where-Object Name -eq 'IpAddress').'#text'
    $workstation = ($data | Where-Object Name -eq 'WorkstationName').'#text'

    Write-Host "`n==== BAD PASSWORD DETECTED ====" -ForegroundColor Yellow
    Write-Host "User:        $username"
    Write-Host "Status:      $status  SubStatus: $subStatus"
    Write-Host "Workstation: $workstation"
    Write-Host "IP Address:  $ipAddress"
    Write-Host "ProcessName: $procName"
    Write-Host "ProcessId:   $procIdHex"

    if ($procIdHex) {
        try {
            $pid = [Convert]::ToInt32($procIdHex, 16)
            Write-Host "ProcessId (dec): $pid"

            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "Actual Process: $($proc.ProcessName) (PID $pid)" -ForegroundColor Green
                Write-Host "Path: $($proc.Path)"
                Write-Host "SessionId: $($proc.SessionId)"
            } else {
                Write-Host "Process no longer exists (it may have exited)." -ForegroundColor Red
            }
        } catch {
            Write-Host "Could not convert PID from hex: $procIdHex" -ForegroundColor Red
        }
    }

    Write-Host "==================================`n"
}

try {
    $watcher.Enabled = $true
}
catch {
    Write-Error "Unable to enable the event watcher. This usually means the session lacks rights to read the Security log. Run PowerShell as Administrator or grant the user 'Manage auditing and security log'."
    $watcher.Dispose()
    return
}

try {
    while ($true) {
        # Keep the subscription alive and drain queued events
        Wait-Event -SourceIdentifier $sourceId | Remove-Event
    }
}
finally {
    Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    $watcher.Dispose()
}

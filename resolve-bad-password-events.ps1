$filter = @{
    LogName   = 'Security'
    Id        = 4625
}

Write-Host "Monitoring for 0xC000006A failed logons... Press Ctrl+C to stop." -ForegroundColor Cyan

Register-WmiEvent -Query "SELECT * FROM Win32_NTLogEvent WHERE Logfile='Security' AND EventCode=4625" -Action {
    # Parse event XML
    $event = [xml]$Event.SourceEvent.Xml
    $data = $event.Event.EventData.Data

    $username     = ($data | Where-Object {$_.Name -eq 'TargetUserName'}).'#text'
    $status       = ($data | Where-Object {$_.Name -eq 'Status'}).'#text'
    $subStatus    = ($data | Where-Object {$_.Name -eq 'SubStatus'}).'#text'
    $processIdHex = ($data | Where-Object {$_.Name -eq 'ProcessId'}).'#text'
    $processName  = ($data | Where-Object {$_.Name -eq 'ProcessName'}).'#text'

    # Only act on bad-password status
    if ($status -eq "0xC000006A") {
        Write-Host "`n==== BAD PASSWORD DETECTED ====" -ForegroundColor Yellow
        Write-Host "User:        $username"
        Write-Host "ProcessName: $processName"
        Write-Host "ProcessId:   $processIdHex"

        # Convert hex PID to decimal if possible
        try {
            $pid = [Convert]::ToInt32($processIdHex,16)
            Write-Host "ProcessId (dec): $pid"

            # Attempt to get the process
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "Actual Process: $($proc.ProcessName)  (PID $pid)" -ForegroundColor Green
                Write-Host "Path: $($proc.Path)"
            } else {
                Write-Host "Process no longer exists (it may have exited)." -ForegroundColor Red
            }
        }
        catch {
            Write-Host "Could not convert PID from hex: $processIdHex" -ForegroundColor Red
        }

        Write-Host "==================================`n"
    }
}

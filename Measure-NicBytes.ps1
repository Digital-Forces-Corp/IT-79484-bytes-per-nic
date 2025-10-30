# This PowerShell 5.1 script measures network adapter traffic with optional background activity subtraction. 
# Captures baseline, monitors peaks during activity, displays bytes transferred and rates (avg/peak) per adapter.
# Supports repeated measurements.
$BYTE_COLUMN_WIDTH = 7
$RATE_COLUMN_WIDTH = 10
$DEFAULT_BACKGROUND_TEST_SECONDS = 5

function Format-ColumnHeader {
    param(
        [string]$Text,
        [int]$Width
    )
    
    $totalPadding = $Width - $Text.Length
    if ($totalPadding -le 0) {
        return $Text
    }
    
    $leftPad = [math]::Floor($totalPadding / 2)
    $rightPad = $totalPadding - $leftPad
    
    return (' ' * $leftPad) + $Text + (' ' * $rightPad)
}

function Add-TableColumn {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Object,
        [Parameter(Mandatory=$true)]
        [string]$HeaderText,
        [Parameter(Mandatory=$true)]
        [int]$Width,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )
    
    $headerName = Format-ColumnHeader $HeaderText $Width
    $paddedValue = $Value.PadLeft($Width)
    $Object | Add-Member -NotePropertyName $headerName -NotePropertyValue $paddedValue
}

function Test-KeyAvailable {
    try {
        return [Console]::KeyAvailable
    } catch {
        return $false
    }
}

function Get-AdapterStats {
    $stats = @{}
    Get-NetAdapterStatistics | ForEach-Object {
        $stats[$_.Name] = [pscustomobject]@{
            Name          = $_.Name
            ReceivedBytes = [int64]$_.ReceivedBytes
            SentBytes     = [int64]$_.SentBytes
        }
    }
    return $stats
}

function Wait-ForEnterWithPeakMonitoring {
    param(
        [hashtable]$StartStats,
        [datetime]$StartTime,
        [int]$MaxDurationSeconds
    )
    
    $peakRxRates = @{}
    $peakTxRates = @{}
    $lastElapsedSecond = -1
    $lastStats = $StartStats
    $lastTime = $StartTime
    $keyCheckingAvailable = Test-KeyAvailable
    
    if (-not $keyCheckingAvailable -and $MaxDurationSeconds -le 0) {
        Read-Host
        $endTime = Get-Date
        $endStats = Get-AdapterStats
        
        return @{
            PeakRxRates = @{}
            PeakTxRates = @{}
        }
    }
    
    do {
        Start-Sleep -Milliseconds 100
        
        $currentTime = Get-Date
        $elapsed = ($currentTime - $StartTime).TotalSeconds
        
        if ($MaxDurationSeconds -gt 0) {
            $currentSecond = [math]::Floor($elapsed)
            if ($currentSecond -gt $lastElapsedSecond) {
                $lastElapsedSecond = $currentSecond
                Write-Host ("`rElapsed: $currentSecond of $MaxDurationSeconds seconds") -NoNewline
            }
            
            if ($elapsed -ge $MaxDurationSeconds) {
                Write-Host ""
                break
            }
        }
        
        if ($keyCheckingAvailable -and (Test-KeyAvailable)) {
            try {
                [Console]::ReadKey($true) | Out-Null
                break
            } catch {
            }
        }
        
        $currentStats = Get-AdapterStats
        
        $intervalDelta = ($currentTime - $lastTime).TotalSeconds
        if ($intervalDelta -gt 0) {
            foreach ($name in $currentStats.Keys) {
                if ($lastStats.ContainsKey($name)) {
                    $rxDelta = $currentStats[$name].ReceivedBytes - $lastStats[$name].ReceivedBytes
                    $txDelta = $currentStats[$name].SentBytes - $lastStats[$name].SentBytes
                    
                    if ($rxDelta -lt 0) {
                        throw "Counter rollover detected on adapter '$name': RxBytes decreased from $($lastStats[$name].ReceivedBytes) to $($currentStats[$name].ReceivedBytes) (delta: $rxDelta)"
                    }
                    if ($txDelta -lt 0) {
                        throw "Counter rollover detected on adapter '$name': TxBytes decreased from $($lastStats[$name].SentBytes) to $($currentStats[$name].SentBytes) (delta: $txDelta)"
                    }
                    
                    $rxRate = $rxDelta / $intervalDelta
                    $txRate = $txDelta / $intervalDelta
                    
                    if (-not $peakRxRates.ContainsKey($name) -or $rxRate -gt $peakRxRates[$name]) {
                        $peakRxRates[$name] = $rxRate
                    }
                    if (-not $peakTxRates.ContainsKey($name) -or $txRate -gt $peakTxRates[$name]) {
                        $peakTxRates[$name] = $txRate
                    }
                }
            }
        }
        
        $lastStats = $currentStats
        $lastTime = $currentTime
    } while ($true)
    
    return @{
        PeakRxRates = $peakRxRates
        PeakTxRates = $peakTxRates
    }
}

function New-MeasurementReport {
    param(
        [hashtable]$StartStats,
        [hashtable]$EndStats,
        [hashtable]$PeakRxRates,
        [hashtable]$PeakTxRates,
        [double]$DurationSeconds,
        [hashtable]$AdapterDescriptions
    )
    
    $commonNames = $StartStats.Keys | Where-Object { $EndStats.ContainsKey($_) }
    
    foreach ($name in $commonNames) {
        $start = $StartStats[$name]
        $end = $EndStats[$name]
        
        $rxDelta = [int64]($end.ReceivedBytes - $start.ReceivedBytes)
        $txDelta = [int64]($end.SentBytes - $start.SentBytes)
        
        if ($rxDelta -lt 0) {
            throw "Counter rollover detected on adapter '$name': RxBytes decreased from $($start.ReceivedBytes) to $($end.ReceivedBytes) (delta: $rxDelta)"
        }
        if ($txDelta -lt 0) {
            throw "Counter rollover detected on adapter '$name': TxBytes decreased from $($start.SentBytes) to $($end.SentBytes) (delta: $txDelta)"
        }
        
        $avgRxRate = if ($DurationSeconds -gt 0) { $rxDelta / $DurationSeconds } else { [double]::NaN }
        $avgTxRate = if ($DurationSeconds -gt 0) { $txDelta / $DurationSeconds } else { [double]::NaN }
        
        $peakRxRate = if ($PeakRxRates -and $PeakRxRates.ContainsKey($name)) { $PeakRxRates[$name] } else { [double]::NaN }
        $peakTxRate = if ($PeakTxRates -and $PeakTxRates.ContainsKey($name)) { $PeakTxRates[$name] } else { [double]::NaN }
        
        [pscustomobject]@{
            AdapterName = $name
            Description = $AdapterDescriptions[$name]
            RxBytes     = $rxDelta
            TxBytes     = $txDelta
            TotalBytes  = $rxDelta + $txDelta
            AvgRxRate   = $avgRxRate
            AvgTxRate   = $avgTxRate
            PeakRxRate  = $peakRxRate
            PeakTxRate  = $peakTxRate
        }
    }
}

function Format-Bytes {
    param([int64]$Bytes)

    $units = @(
        @{ Threshold = [decimal](1024 * 1024 * 1024 * 1024); Suffix = "TiB" }
        @{ Threshold = [decimal](1024 * 1024 * 1024);        Suffix = "GiB" }
        @{ Threshold = [decimal](1024 * 1024);               Suffix = "MiB" }
        @{ Threshold = [decimal]1024;                        Suffix = "KiB" }
        @{ Threshold = [decimal]1;                           Suffix = "B  " }
    )

    $sign = ""
    $magnitude = [decimal]$Bytes
    if ($magnitude -lt 0) {
        $sign = "-"
        $magnitude = -$magnitude
    }

    foreach ($unit in $units) {
        if ($magnitude -ge $unit.Threshold) {
            $scaledValue = [decimal]::Floor($magnitude / $unit.Threshold)
            return "{0}{1:n0} {2}" -f $sign, $scaledValue, $unit.Suffix
        }
    }

    return "{0}0 B  " -f $sign
}

function Format-BytesPerSecond {
    param([double]$BytesPerSecond)

    if ([double]::IsNaN($BytesPerSecond)) {
        return "N/A"
    }

    $bitsPerSecond = $BytesPerSecond * 8
    $formatted = Format-Bytes ([int64]$bitsPerSecond)
    $formatted = $formatted -replace 'B', 'b'
    $trimmed = $formatted.TrimEnd()
    return $trimmed + '/s' + (' ' * ($formatted.Length - $trimmed.Length))
}

function Show-NetworkTable {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [object[]]$Report,
        [Parameter(Mandatory=$true)]
        [datetime]$StartTime,
        [Parameter(Mandatory=$true)]
        [datetime]$EndTime,
        [Parameter(Mandatory=$true)]
        [bool]$BackgroundSubtracted
    )

    $durationSeconds = ($EndTime - $StartTime).TotalSeconds
    Write-Host "`nMeasurement duration: $($durationSeconds.ToString('F1')) seconds" -NoNewline
    if ($BackgroundSubtracted) {
        Write-Host " - Showing Average adjusted for background activity (AAvg) greater than 0" -NoNewline
    }
    Write-Host ""

    $filteredReport = @($Report | Where-Object { $_.AvgRxRate -gt 0 -or $_.AvgTxRate -gt 0 })

    if ($filteredReport.Count -eq 0) {
        if ($Report.Count -eq 0) {
            Write-Host "No network adapters found."
        } else {
            Write-Host "No network activity detected (all adapters filtered out due to zero net traffic)."
        }
    } else {
        $formattedReport = @($filteredReport | Sort-Object TotalBytes -Descending | ForEach-Object {
            $obj = [pscustomobject]@{
                AdapterName                                 = $_.AdapterName
                Description                                 = $_.Description
                (Format-ColumnHeader "Total" $BYTE_COLUMN_WIDTH) = (Format-Bytes $_.TotalBytes).PadLeft($BYTE_COLUMN_WIDTH)
                (Format-ColumnHeader "Rx" $BYTE_COLUMN_WIDTH)    = (Format-Bytes $_.RxBytes).PadLeft($BYTE_COLUMN_WIDTH)
                (Format-ColumnHeader "Tx" $BYTE_COLUMN_WIDTH)    = (Format-Bytes $_.TxBytes).PadLeft($BYTE_COLUMN_WIDTH)
            }

            if ($_.PSObject.Properties.Name -contains 'BgRxRate') {
                Add-TableColumn $obj "Bg Rx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.BgRxRate)
                Add-TableColumn $obj "Bg Tx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.BgTxRate)
            }

            $avgPrefix = if ($BackgroundSubtracted) { "AAvg" } else { "Avg" }
            Add-TableColumn $obj "Peak Rx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.PeakRxRate)
            Add-TableColumn $obj "Peak Tx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.PeakTxRate)
            Add-TableColumn $obj "$avgPrefix Rx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.AvgRxRate)
            Add-TableColumn $obj "$avgPrefix Tx/s" $RATE_COLUMN_WIDTH (Format-BytesPerSecond $_.AvgTxRate)
            
            $obj
        })

        $formattedReport | Format-Table -Property * | Out-String | Write-Host
    }
}

function Invoke-NetworkMeasurement {
    param(
        [string]$StartPrompt,
        [string]$EndPrompt,
        [hashtable]$AdapterDescriptions,
        [int]$MaxDurationSeconds
    )

    if ($StartPrompt) {
        Write-Host $StartPrompt -NoNewline
        Read-Host
    }

    $startTime = Get-Date
    $startStats = Get-AdapterStats

    if ($EndPrompt) {
        Write-Host $EndPrompt -NoNewline
    }

    $peakData = Wait-ForEnterWithPeakMonitoring -StartStats $startStats -StartTime $startTime -MaxDurationSeconds $MaxDurationSeconds

    $endTime = Get-Date
    $endStats = Get-AdapterStats

    $durationSeconds = ($endTime - $startTime).TotalSeconds

    $report = New-MeasurementReport -StartStats $startStats -EndStats $endStats `
        -PeakRxRates $peakData.PeakRxRates -PeakTxRates $peakData.PeakTxRates `
        -DurationSeconds $durationSeconds -AdapterDescriptions $AdapterDescriptions

    return @{
        StartTime = $startTime
        EndTime   = $endTime
        Report    = $report
    }
}

function Remove-BackgroundActivity {
    param(
        [object[]]$Report,
        [object[]]$BackgroundReport
    )

    return $Report | ForEach-Object {
        $currentAdapter = $_
        $bgAdapter = $BackgroundReport | Where-Object { $_.AdapterName -eq $currentAdapter.AdapterName } | Select-Object -First 1
        $bgAvgRxRate = if ($bgAdapter) { $bgAdapter.AvgRxRate } else { 0 }
        $bgAvgTxRate = if ($bgAdapter) { $bgAdapter.AvgTxRate } else { 0 }

        $currentAdapter | Add-Member -NotePropertyName BgRxRate -NotePropertyValue $bgAvgRxRate -Force
        $currentAdapter | Add-Member -NotePropertyName BgTxRate -NotePropertyValue $bgAvgTxRate -Force
        
        $currentAdapter.AvgRxRate = if ([double]::IsNaN($currentAdapter.AvgRxRate)) { [double]::NaN } else { $currentAdapter.AvgRxRate - $bgAvgRxRate }
        $currentAdapter.AvgTxRate = if ([double]::IsNaN($currentAdapter.AvgTxRate)) { [double]::NaN } else { $currentAdapter.AvgTxRate - $bgAvgTxRate }
        $currentAdapter.PeakRxRate = if ([double]::IsNaN($currentAdapter.PeakRxRate)) { [double]::NaN } else { $currentAdapter.PeakRxRate - $bgAvgRxRate }
        $currentAdapter.PeakTxRate = if ([double]::IsNaN($currentAdapter.PeakTxRate)) { [double]::NaN } else { $currentAdapter.PeakTxRate - $bgAvgTxRate }
        $currentAdapter
    }
}

$adapterDescriptions = @{}
Get-NetAdapter | ForEach-Object {
    $adapterDescriptions[$_.Name] = $_.InterfaceDescription
}

$backgroundDuration = $null
do {
    Write-Host "How long do you want to run to determine background network load? (Enter seconds, or 0 to skip) [$DEFAULT_BACKGROUND_TEST_SECONDS]: " -NoNewline
    $durationInput = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($durationInput)) {
        $backgroundDuration = $DEFAULT_BACKGROUND_TEST_SECONDS
        break
    } elseif ($durationInput -match '^\d+$') {
        $backgroundDuration = [int]$durationInput
        if ($backgroundDuration -eq 0) {
            $backgroundDuration = $null
        }
        break
    } else {
        Write-Host "Invalid input. Please enter a number."
    }
} while ($true)

$subtractBackground = $false
if ($null -ne $backgroundDuration) {
    $bgMeasurement = Invoke-NetworkMeasurement `
        -StartPrompt "" `
        -EndPrompt "" `
        -AdapterDescriptions $adapterDescriptions `
        -MaxDurationSeconds $backgroundDuration

    Show-NetworkTable -Report $bgMeasurement.Report -StartTime $bgMeasurement.StartTime -EndTime $bgMeasurement.EndTime -BackgroundSubtracted $false

    Write-Host "Do you want to subtract background activity from further statistics? (Y/[N]): " -NoNewline
    $response = Read-Host
    if ($response -match '^[Yy]') {
        $subtractBackground = $true
    }
}

while ($true) {
    $measurement = Invoke-NetworkMeasurement `
        -StartPrompt "Press Enter to capture activity" `
        -EndPrompt "Press Enter to end capture" `
        -AdapterDescriptions $adapterDescriptions `
        -MaxDurationSeconds 0

    $report = $measurement.Report

    if ($subtractBackground) {
        $report = Remove-BackgroundActivity -Report $report -BackgroundReport $bgMeasurement.Report
    }

    Show-NetworkTable -Report $report -StartTime $measurement.StartTime -EndTime $measurement.EndTime -BackgroundSubtracted $subtractBackground
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
if ($host.Name -ne 'ConsoleHost') { chcp 65001 | Out-Null }

Write-Output "# Hardware Report: $($env:COMPUTERNAME)"
Write-Output "Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output ""

# System & CPU
$Mobo = (Get-CimInstance Win32_BaseBoard).Product; if (-not $Mobo) { $Mobo = "Generic Motherboard" }
$CPU = (Get-CimInstance Win32_Processor).Name
Write-Output "## 🖥️ System & CPU"
Write-Output "Stack: **$Mobo** | **$CPU**"

# RAM
Write-Output "## 🧠 RAM Configuration"
Write-Output "| Slot | Size | Speed | Details |"
Write-Output "|:---|:---|:---|:---|"
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    $Size = "$([Math]::Round($_.Capacity / 1GB, 0)) GB"
    $Part = if ($_.PartNumber) { $_.PartNumber.Trim() } else { "-" }
    $Vendor = if ($_.Manufacturer) { $_.Manufacturer.Trim() } else { "Generic" }
    Write-Output "| $($_.DeviceLocator) | $Size | $($_.ConfiguredClockSpeed) MT/s | $Vendor ($Part) |"
}
Write-Output ""

# GPU
Write-Output "## 🎮 Graphics (GPU)"
Write-Output "| Device | Driver |"
Write-Output "|:---|:---|"
Get-CimInstance Win32_VideoController | ForEach-Object {
    Write-Output "| $($_.Name) | $($_.DriverVersion) |"
}
Write-Output ""

# Network
Write-Output "## 🌐 Network Interfaces"
Write-Output "| Interface | Model | Status | IP Address |"
Write-Output "|:---|:---|:---|:---|"
Get-NetAdapter | Where-Object { $_.InterfaceDescription -notmatch "Virtual|Hyper-V|VirtualBox|Bluetooth" } | ForEach-Object {
    $IPAddrRaw = (Get-NetIPAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $IPAddr = if ($null -ne $IPAddrRaw) { $IPAddrRaw -join ", " } else { "-" }
    $Status = if ($_.Status -eq 2) { "UP" } else { "DOWN" }
    Write-Output "| $($_.Name) | $($_.InterfaceDescription) | $Status | $IPAddr |"
}
Write-Output ""

# Storage
Write-Output "## 💾 Storage Devices"
Write-Output "| Device | Model | Size | Type | Health | Notes |"
Write-Output "|:---|:---|:---|:---|:---|:---|"
Get-PhysicalDisk | Where-Object { $_.BusType -notmatch "USB" } | ForEach-Object {
    $SizeGB = "$([Math]::Round($_.Size / 1GB, 0))G"
    $Type = if ($_.MediaType -eq "SSD") { "SSD/NVMe" } else { "HDD" }
    $Notes = "OK"

    try {
        $Smart = $_ | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($null -ne $Smart -and $Smart.Wear -gt 0) { $Notes = "Wear: $($Smart.Wear)%" }
    } catch {
        $Notes = "N/A (No Counters)"
    }
    
    $Health = if ($_.HealthStatus -eq "Healthy") { "PASSED" } else { $_.HealthStatus.ToUpper() }
    Write-Output "| Disk $($_.DeviceId) | $($_.Model) | $SizeGB | $Type | $Health | $Notes |"
}

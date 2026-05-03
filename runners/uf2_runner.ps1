# SPDX-License-Identifier: NOASSERTION
# The code is based on https://github.com/kot149/zmk-workspace/blob/main/flash.ps1
param(
    [Parameter(Mandatory=$true)]
    [string]$Uf2File,
    [string]$COMPort,
    [switch]$NoTouchReset,
    [int]$TouchResetBaudRate = 1200
)

# Check if the drive is a UF2 loader
function Test-IsUf2Loader {
    param([string]$DriveLetter)

    $drivePath = $DriveLetter + ":\"

    # Check if the drive is accessible
    if (-not (Test-Path $drivePath)) {
        return $false
    }

    try {
        # Get drive information
        $drive = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
        if (-not $drive) {
            return $false
        }

        # Check the volume label
        $volume = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction SilentlyContinue
        if ($volume -and $volume.VolumeName -match "UF2") {
            return $true
        }

        # Check if the INFO_UF2.TXT file exists
        $infoFile = Join-Path $drivePath "INFO_UF2.TXT"
        if (Test-Path $infoFile) {
            return $true
        }

        # Check if the INDEX.HTM file exists (often found in UF2 loaders)
        $indexFile = Join-Path $drivePath "INDEX.HTM"
        if (Test-Path $indexFile) {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

function Write-Firmware {
    param([string]$TargetDrive, [string]$SourceFile)

    $targetPath = Join-Path ($TargetDrive + ":\") (Split-Path $SourceFile -Leaf)

    Write-Host "Copying firmware to drive $TargetDrive..."

    Copy-Item -Path $SourceFile -Destination $targetPath -Force

    Write-Host "Flash completed!"
}

# Check if the firmware file exists
# if (-not (Test-Path $Uf2File)) {
#     Write-Error "File '$Uf2File' not found."
#     exit 1
# }

Write-Host "Firmware file: $Uf2File"


#
# Step1: Find the UF2 loader drive.
#        If found, copy the UF2 file and exit.
#
Write-Host "Checking existing drives for UF2 loader..."
$initialDrives = Get-PSDrive -PSProvider FileSystem

foreach ($drive in $initialDrives) {
    if (Test-IsUf2Loader -DriveLetter $drive.Name) {
        Write-Host "UF2 loader found on drive $($drive.Name)"
        Write-Firmware -TargetDrive $drive.Name -SourceFile $Uf2File
        exit 0
    }
}

Write-Host "No UF2 loader found in existing drives."

#
# Step2: Try touch-reset via COM port
#
if (-not $NoTouchReset -and -not $COMPort) {
    # If COMPort not specified, list available ports and prompt to select
    $ports = Get-CimInstance -ClassName Win32_SerialPort | Sort-Object DeviceID | ForEach-Object {
        $usbName = $null
        try {
            # Walk up the parent chain to find the USB composite device node
            # (interface-level nodes contain "&MI_", skip those)
            $instanceId = $_.PNPDeviceID
            while ($true) {
                $instanceId = (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
                if (-not $instanceId) { break }
                if ($instanceId -notmatch '&MI_') {
                    # This is the USB device node — get the bus-reported product string
                    $usbName = (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data
                    break
                }
            }
        } catch {}
        [PSCustomObject]@{
            COMPort = $_.DeviceID
            Name    = if ($usbName) { $usbName } else { $_.Name }
        }
    }

    if ($ports.Count -eq 0) {
        Write-Host "No COM ports found. Skipping touch reset."
    } else {
        Write-Host "Available COM ports:"
        for ($i = 0; $i -lt $ports.Count; $i++) {
            Write-Host "  [$($i + 1)] $($ports[$i].COMPort) - $($ports[$i].Name)"
        }
        Write-Host "  [0] Skip touch reset"

        do {
            $selection = Read-Host "Select a COM port (0-$($ports.Count))"
        } while ($selection -notmatch '^\d+$' -or [int]$selection -lt 0 -or [int]$selection -gt $ports.Count)

        if ([int]$selection -gt 0) {
            $COMPort = $ports[[int]$selection - 1].COMPort
        }
    }
}
if (-not $NoTouchReset -and $COMPort) {
    Write-Host "Touching reset via COM port $COMPort at baud rate $TouchResetBaudRate..."
    $port = new-Object System.IO.Ports.SerialPort $COMPort, $TouchResetBaudRate, None, 8, one
    $port.DtrEnable = $true
    $port.Open()
    Start-Sleep -Milliseconds 100
    $port.DtrEnable = $false
    $port.Close()
}

Write-Host "Waiting for new UF2 loader drive... (Press 'q' to cancel)"

try {
    while ($true) {
        # Check if a key is pressed (KeyAvailable throws when stdin is redirected/non-interactive)
        $keyAvailable = $false
        try { $keyAvailable = [Console]::KeyAvailable } catch {}
        if ($keyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') {
                Write-Host "`nCancelled."
                exit 0
            }
        }

        Start-Sleep -Milliseconds 100
        $currentDrives = Get-PSDrive -PSProvider FileSystem

        # Detect new drives
        $newDrives = $currentDrives | Where-Object {
            $drive = $_
            -not ($initialDrives | Where-Object { $_.Name -eq $drive.Name })
        }

        if ($newDrives) {
            foreach ($newDrive in $newDrives) {
                Write-Host "New drive detected: $($newDrive.Name)"

                if (Test-IsUf2Loader -DriveLetter $newDrive.Name) {
                    Write-Host "UF2 loader detected on drive $($newDrive.Name)"
                    Write-Firmware -TargetDrive $newDrive.Name -SourceFile $Uf2File
                    exit 0
                } else {
                    Write-Host "Drive $($newDrive.Name) is not a UF2 loader, skipping..."
                }
            }

            # New drive added, update the initial drive list
            $initialDrives = $currentDrives
        }
    }
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}

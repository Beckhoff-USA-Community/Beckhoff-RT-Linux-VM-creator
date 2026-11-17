<#
.SYNOPSIS
    Creates and configures a Beckhoff RT Linux virtual machine in VirtualBox.

.DESCRIPTION
    Creates a VirtualBox VM with EFI firmware, a NAT adapter for internet access and a
    host-only adapter for host-to-VM communication. The Beckhoff RT Linux installer image
    is converted to a VDI installer disk, and an empty, dynamically allocated VHD is created
    as the runtime (OS) disk. Both disks are attached to a SATA controller and VirtualBox is
    opened so you can complete the installation.

    Any path or sizing parameter you leave out is asked for interactively, unless
    -NonInteractive is given, in which case the defaults are used and missing paths are an error.

    A VM created by this script is intended for training, CI/CD testing and evaluation only.
    It is not supported for production use.

.PARAMETER vmname
    Name of the virtual machine. Must not already exist in VirtualBox.

.PARAMETER linuxImageFile
    Path to the Beckhoff RT Linux installer .img file. Relative paths are resolved
    against the current directory. If omitted or not found, a file picker is shown.

.PARAMETER vmStoragePath
    Directory in which the VM folder is created. If omitted or not found, a folder
    picker is shown, starting at the VirtualBox default machine folder.

.PARAMETER virtualBoxPath
    VirtualBox installation directory containing VBoxManage.exe.

.PARAMETER cpus
    Number of virtual CPUs. Default 4.

.PARAMETER memoryMB
    Amount of RAM in MB. Default 4096.

.PARAMETER installerDiskSizeGB
    Size of the installer disk in GiB. Must be at least the size of the image file.
    Default 8.

.PARAMETER runtimeDiskSizeGB
    Size of the runtime (OS) disk in GiB. Dynamically allocated, so only the space
    actually used by the guest is consumed on the host. Default 32.

.PARAMETER hostOnlySubnet
    First three octets of the host-only network. The host gets .1, the DHCP server .2
    and VMs receive .11 to .99. Default 192.168.42.

.PARAMETER NonInteractive
    Never show dialogs or prompts. Missing or invalid paths are errors, sizing
    defaults are used as-is, VirtualBox is not opened and the script does not
    pause before exiting. Intended for CI/CD use.

.EXAMPLE
    .\Create-TcRTLinuxVM.ps1 -vmname "MyRTLinuxVM"

    Interactive: select the image and storage folder in dialogs, then answer the
    sizing prompts (Enter accepts the default).

.EXAMPLE
    .\Create-TcRTLinuxVM.ps1 -vmname "CI-RTLinux" -linuxImageFile "C:\images\Beckhoff-RT-Linux-440542-installer-amd64.img" -vmStoragePath "D:\VMs" -NonInteractive

    Unattended: create the VM with default sizing and exit without opening VirtualBox.

.NOTES
    Copyright (c) 2026 Beckhoff Automation LLC
    SPDX-License-Identifier: 0BSD
    See the LICENSE file in the repository root for the full license text.

    Requires a Windows host with VirtualBox installed. Works with Windows PowerShell 5.1
    and PowerShell 7.
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="Name your VM")]
    [ValidateNotNullOrEmpty()]
    [string]$vmname,
    [Parameter(Mandatory=$false, HelpMessage="Select your Beckhoff RT Linux image")]
    [string]$linuxImageFile = $null,
    [Parameter(Mandatory=$false, HelpMessage="Where do you want to store the VM?")]
    [string]$vmStoragePath = $null,
    [Parameter(Mandatory=$false, HelpMessage="Where is your VirtualBox installation?")]
    [string]$virtualBoxPath = 'C:\Program Files\Oracle\VirtualBox',
    [Parameter(Mandatory=$false, HelpMessage="Number of virtual CPUs")]
    [ValidateRange(1, 64)]
    [int]$cpus = 4,
    [Parameter(Mandatory=$false, HelpMessage="Amount of RAM in MB")]
    [ValidateRange(512, 262144)]
    [int]$memoryMB = 4096,
    [Parameter(Mandatory=$false, HelpMessage="Size of the installer disk in GiB")]
    [ValidateRange(1, 2048)]
    [int]$installerDiskSizeGB = 8,
    [Parameter(Mandatory=$false, HelpMessage="Size of the runtime (OS) disk in GiB")]
    [ValidateRange(1, 2048)]
    [int]$runtimeDiskSizeGB = 32,
    [Parameter(Mandatory=$false, HelpMessage="First three octets of the host-only network, e.g. 192.168.42")]
    [ValidatePattern('^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){2}$')]
    [string]$hostOnlySubnet = '192.168.42',
    [Parameter(Mandatory=$false, HelpMessage="Never prompt; fail on missing input and do not open VirtualBox")]
    [switch]$NonInteractive
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# Show a file picker dialog for the installer image
function Show-FilePickerDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = "Select Beckhoff RT Linux Image"
    $fileDialog.Filter = "Image Files (*.img;*.iso)|*.img;*.iso|All Files (*.*)|*.*"
    $fileDialog.InitialDirectory = (Get-Location).Path

    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $fileDialog.FileName
    }
    return $null
}

# Show a folder picker dialog for the VM storage location
function Show-FolderPickerDialog {
    param([string]$initialDirectory)

    Add-Type -AssemblyName System.Windows.Forms
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select folder to store the Virtual Machine"

    if (![string]::IsNullOrEmpty($initialDirectory) -and (Test-Path $initialDirectory)) {
        $folderDialog.SelectedPath = $initialDirectory
    }

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderDialog.SelectedPath
    }
    return $null
}

# Prompt for an integer, accepting Enter for the default
function Read-IntWithDefault {
    param(
        [string]$prompt,
        [int]$default,
        [int]$min,
        [int]$max
    )

    while ($true) {
        $answer = Read-Host "$prompt [$default]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $default
        }
        $value = 0
        if ([int]::TryParse($answer.Trim(), [ref]$value) -and $value -ge $min -and $value -le $max) {
            return $value
        }
        Write-Warning "Please enter a whole number between $min and $max."
    }
}

# Run VBoxManage and fail loudly if it returns a non-zero exit code.
# -ShowOutput streams the output live (useful for long conversions).
# -IgnoreErrors returns the output regardless of exit code.
function Invoke-VBoxManage {
    param(
        [switch]$ShowOutput,
        [switch]$IgnoreErrors,
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Arguments
    )

    if ($ShowOutput) {
        & $script:vboxManage @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
        $output = $null
    } else {
        $output = & $script:vboxManage @Arguments 2>&1 | ForEach-Object { "$_" }
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $IgnoreErrors) {
        $detail = if ($output) { "`n" + ($output -join "`n") } else { "" }
        throw "VBoxManage $($Arguments -join ' ') failed with exit code $exitCode.$detail"
    }
    return $output
}

# Get the VirtualBox default machine folder
function Get-VirtualBoxDefaultVMFolder {
    try {
        $line = Invoke-VBoxManage -IgnoreErrors list systemproperties | Where-Object { $_ -match "Default machine folder:" }
        if ($line) {
            $defaultFolder = ($line -split "Default machine folder:\s*")[1].Trim()
            if (Test-Path $defaultFolder) {
                return $defaultFolder
            }
        }
    }
    catch {
        # Fall through to the common default location
    }
    return "$env:USERPROFILE\VirtualBox VMs"
}

# Print an error line without PowerShell's call-site decoration
function Write-ErrorLine {
    param([string]$message)
    Write-Host "[ERROR]  $message" -ForegroundColor Red
}

# Stop the script with a message. Exit code 0 is a user cancel (warning);
# anything else is an error.
function Exit-WithMessage {
    param([string]$message, [int]$code = 1)
    if ($code -eq 0) { Write-Warning $message } else { Write-ErrorLine $message }
    exit $code
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

$workingDirectory = (Get-Location).Path

# This script uses Windows Forms dialogs and Windows CIM queries, so it needs a Windows host.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Exit-WithMessage "This script requires a Windows host."
}

# VM names end up as folder names, so reject characters that are invalid in a path.
$invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
if ($vmname.IndexOfAny($invalidChars) -ge 0) {
    Exit-WithMessage "VM name '$vmname' contains characters that are not allowed in a folder name."
}

# 1) Ensure VirtualBox is installed
$script:vboxManage = Join-Path $virtualBoxPath "VBoxManage.exe"
if (!(Test-Path $script:vboxManage)) {
    Write-ErrorLine "VirtualBox not found at $virtualBoxPath"
    Write-Host "Please install VirtualBox from https://www.virtualbox.org/wiki/Downloads"
    Write-Host "Or use the -virtualBoxPath parameter to specify your VirtualBox installation location."
    exit 1
}

# 2) Refuse to clobber an existing VM of the same name
Invoke-VBoxManage -IgnoreErrors showvminfo $vmname | Out-Null
if ($LASTEXITCODE -eq 0) {
    Exit-WithMessage "A VM named '$vmname' already exists in VirtualBox. Choose a different name or remove the existing VM first."
}

# ---------------------------------------------------------------------------
# Input selection
# ---------------------------------------------------------------------------

# 3) VM storage location
if (-not [string]::IsNullOrEmpty($vmStoragePath) -and (Test-Path $vmStoragePath)) {
    $vmBasePath = (Resolve-Path $vmStoragePath).Path
} else {
    if (-not [string]::IsNullOrEmpty($vmStoragePath)) {
        $msg = "Specified VM storage path does not exist: $vmStoragePath"
        if ($NonInteractive) { Exit-WithMessage $msg }
        Write-Warning $msg
    } elseif ($NonInteractive) {
        Exit-WithMessage "-vmStoragePath is required in non-interactive mode."
    }

    $defaultVMFolder = Get-VirtualBoxDefaultVMFolder
    Write-Output "[>]  Please select where to store the Virtual Machine..."
    Write-Output "    (Default VirtualBox location: $defaultVMFolder)"

    $selectedFolder = Show-FolderPickerDialog -initialDirectory $defaultVMFolder
    if ($null -eq $selectedFolder) {
        Exit-WithMessage "No storage location selected. Exiting." 0
    }
    $vmBasePath = $selectedFolder
    Write-Output "Selected storage location: $vmBasePath"
}

$vmDir = Join-Path $vmBasePath $vmname
if (Test-Path $vmDir) {
    Exit-WithMessage "The folder '$vmDir' already exists. Remove it or choose a different VM name or storage location."
}

# 4) Installer image
$imagePath = $null
if (-not [string]::IsNullOrEmpty($linuxImageFile)) {
    if ([System.IO.Path]::IsPathRooted($linuxImageFile)) {
        $candidate = $linuxImageFile
    } else {
        $candidate = Join-Path $workingDirectory $linuxImageFile
    }
    if (Test-Path $candidate -PathType Leaf) {
        $imagePath = (Resolve-Path $candidate).Path
    } else {
        $msg = "Beckhoff RT Linux image not found: $candidate"
        if ($NonInteractive) { Exit-WithMessage $msg }
        Write-Warning $msg
    }
} elseif ($NonInteractive) {
    Exit-WithMessage "-linuxImageFile is required in non-interactive mode."
}

if ($null -eq $imagePath) {
    Write-Output "[>]  Please select your Beckhoff RT Linux image file..."
    $selectedFile = Show-FilePickerDialog
    if ($null -eq $selectedFile) {
        Exit-WithMessage "No file selected. Exiting." 0
    }
    $imagePath = $selectedFile
}
Write-Output "Selected image: $(Split-Path $imagePath -Leaf)"

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------

# 5) VM sizing (CPUs, memory and disk sizes)
# The installer disk must be at least as large as the image, since VirtualBox cannot shrink a disk.
$imageSizeBytes     = (Get-Item $imagePath).Length
$minInstallerDiskGB = [int][math]::Ceiling($imageSizeBytes / 1GB)
$hostCpuCount       = [Environment]::ProcessorCount
$hostMemoryMB       = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)

if ($installerDiskSizeGB -lt $minInstallerDiskGB -and -not $PSBoundParameters.ContainsKey('installerDiskSizeGB')) {
    $installerDiskSizeGB = $minInstallerDiskGB
}

# Prompt for any sizing value that was not passed on the command line
$promptForSizing = -not $NonInteractive -and -not (
    $PSBoundParameters.ContainsKey('cpus') -and
    $PSBoundParameters.ContainsKey('memoryMB') -and
    $PSBoundParameters.ContainsKey('installerDiskSizeGB') -and
    $PSBoundParameters.ContainsKey('runtimeDiskSizeGB'))
if ($promptForSizing) {
    Write-Output "[>]  VM sizing (press Enter to accept the default)"
    if (-not $PSBoundParameters.ContainsKey('cpus')) {
        $cpus = Read-IntWithDefault -prompt "    Number of CPUs (host has $hostCpuCount)" -default $cpus -min 1 -max 64
    }
    if (-not $PSBoundParameters.ContainsKey('memoryMB')) {
        $memoryMB = Read-IntWithDefault -prompt "    Memory in MB (host has $hostMemoryMB)" -default $memoryMB -min 512 -max 262144
    }
    if (-not $PSBoundParameters.ContainsKey('installerDiskSizeGB')) {
        $installerDiskSizeGB = Read-IntWithDefault -prompt "    Installer disk size in GiB (minimum $minInstallerDiskGB)" -default $installerDiskSizeGB -min $minInstallerDiskGB -max 2048
    }
    if (-not $PSBoundParameters.ContainsKey('runtimeDiskSizeGB')) {
        $runtimeDiskSizeGB = Read-IntWithDefault -prompt "    Runtime disk size in GiB" -default $runtimeDiskSizeGB -min 1 -max 2048
    }
}

if ($installerDiskSizeGB -lt $minInstallerDiskGB) {
    Exit-WithMessage "Installer disk size ($installerDiskSizeGB GiB) is smaller than the image ($minInstallerDiskGB GiB). VirtualBox cannot shrink a disk."
}
if ($cpus -gt $hostCpuCount) {
    Write-Warning "Requested $cpus CPUs but the host only has $hostCpuCount. The VM may be slow or fail to start."
}
if ($memoryMB -gt ($hostMemoryMB / 2)) {
    Write-Warning "Requested $memoryMB MB of RAM, more than half of the host's $hostMemoryMB MB. The host may run short of memory."
}

# Free space check. The installer VDI is roughly the size of the image; the runtime VHD
# is dynamically allocated and starts small, so the image size plus a margin is enough.
try {
    $drive = [System.IO.DriveInfo]::new($vmBasePath)
    $requiredBytes = $imageSizeBytes + 1GB
    if ($drive.AvailableFreeSpace -lt $requiredBytes) {
        $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $needGB = [math]::Round($requiredBytes / 1GB, 1)
        Exit-WithMessage "Not enough free space on $($drive.Name): $freeGB GiB free, about $needGB GiB needed."
    }
}
catch [System.ArgumentException] {
    # Network paths and other non-drive locations: skip the check
}

Write-Output "    CPUs: $cpus | Memory: $memoryMB MB | Installer disk: $installerDiskSizeGB GiB | Runtime disk: $runtimeDiskSizeGB GiB"

# ---------------------------------------------------------------------------
# VM creation. Anything that fails from here on removes what was created.
# ---------------------------------------------------------------------------

$hostIp        = "$hostOnlySubnet.1"
$dhcpIp        = "$hostOnlySubnet.2"
$dhcpLower     = "$hostOnlySubnet.11"
$dhcpUpper     = "$hostOnlySubnet.99"
$installerDisk = Join-Path $vmDir "RTLinux_installer.vdi"
$runtimeDisk   = Join-Path $vmDir "RTLinux.vhd"
$vmCreated     = $false

try {
    # 6) Create & configure the VM
    Write-Output "[VM]  Creating VM '$vmname' (Debian 64-bit)"
    Invoke-VBoxManage createvm --name $vmname --basefolder $vmBasePath --ostype Debian_64 --register | Out-Null
    $vmCreated = $true
    Invoke-VBoxManage modifyvm $vmname `
        --cpus $cpus --memory $memoryMB --vram 128 `
        --acpi on --hpet on `
        --graphicscontroller VMSVGA `
        --firmware efi `
        --usb on `
        --bios-logo-display-time 5000 | Out-Null

    # 7) Configure network adapters
    Write-Output "[NET]  Configuring network adapters..."

    # Look for an existing host-only interface that already has our host IP
    $hostOnlyNet = $null
    $currentInterface = $null
    foreach ($line in (Invoke-VBoxManage list hostonlyifs)) {
        if ($line -match "^Name:\s+(.+)$") {
            $currentInterface = $matches[1].Trim()
        }
        if ($line -match "^IPAddress:\s+$([regex]::Escape($hostIp))\s*$" -and $currentInterface) {
            $hostOnlyNet = $currentInterface
            Write-Output "   Found existing host-only network: $hostOnlyNet"
            break
        }
    }

    # Otherwise create a new one rather than reconfiguring an adapter that may be in use
    if (-not $hostOnlyNet) {
        Write-Output "   Creating new host-only network adapter"
        foreach ($line in (Invoke-VBoxManage hostonlyif create)) {
            if ($line -match "Interface '(.+)' was successfully created") {
                $hostOnlyNet = $matches[1]
            }
        }
        if (-not $hostOnlyNet) {
            throw "Could not determine the name of the newly created host-only adapter."
        }
        Write-Output "   Configuring host-only network ($hostOnlySubnet.0/24)"
        Invoke-VBoxManage hostonlyif ipconfig $hostOnlyNet --ip $hostIp --netmask 255.255.255.0 | Out-Null
    }

    # DHCP server for the host-only network
    Write-Output "   Configuring DHCP server ($dhcpLower - $dhcpUpper)"
    Invoke-VBoxManage -IgnoreErrors dhcpserver remove --network=HostInterfaceNetworking-$hostOnlyNet | Out-Null
    Invoke-VBoxManage dhcpserver add --network=HostInterfaceNetworking-$hostOnlyNet `
        --server-ip=$dhcpIp --netmask=255.255.255.0 `
        --lower-ip=$dhcpLower --upper-ip=$dhcpUpper --enable | Out-Null

    Write-Output "   Enabling NAT adapter for internet access"
    Invoke-VBoxManage modifyvm $vmname --nic1 nat | Out-Null

    Write-Output "   Enabling Host-Only adapter for host communication"
    Invoke-VBoxManage modifyvm $vmname --nic2 hostonly --hostonlyadapter2 $hostOnlyNet | Out-Null

    # 8) Convert the raw installer image into a VDI
    Write-Output "[>>]  Converting image to VDI format"
    Invoke-VBoxManage -ShowOutput convertfromraw --format VDI $imagePath $installerDisk

    Write-Output "[>>]  Resizing installer disk to $installerDiskSizeGB GiB"
    Invoke-VBoxManage -ShowOutput modifymedium disk $installerDisk --resize ($installerDiskSizeGB * 1024)

    # 9) Create SATA controller and attach disks
    Write-Output "[HDD]  Adding SATA controller"
    Invoke-VBoxManage storagectl $vmname --name SATA --add sata --controller IntelAhci --hostiocache on --bootable on | Out-Null

    Write-Output "[+]  Attaching installer disk to port 1"
    Invoke-VBoxManage storageattach $vmname --storagectl SATA --port 1 --device 0 --type hdd --medium $installerDisk | Out-Null

    Write-Output "[+]  Creating runtime disk ($runtimeDiskSizeGB GiB, dynamically allocated)"
    Invoke-VBoxManage -ShowOutput createmedium --filename $runtimeDisk --size ($runtimeDiskSizeGB * 1024) --format VHD

    Write-Output "[+]  Attaching runtime disk to port 0"
    Invoke-VBoxManage storageattach $vmname --storagectl SATA --port 0 --device 0 --type hdd --medium $runtimeDisk | Out-Null
}
catch {
    Write-ErrorLine "VM creation failed: $($_.Exception.Message)"
    Write-Host "[X]  Cleaning up..."
    foreach ($disk in @($installerDisk, $runtimeDisk)) {
        if (Test-Path $disk) {
            Invoke-VBoxManage -IgnoreErrors closemedium disk $disk --delete | Out-Null
        }
    }
    if ($vmCreated) {
        Invoke-VBoxManage -IgnoreErrors unregistervm $vmname --delete | Out-Null
    }
    if (Test-Path $vmDir) {
        Remove-Item -Recurse -Force $vmDir -ErrorAction SilentlyContinue
    }
    exit 1
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host "[OK]  VM created at: $vmDir"
Write-Host "[OK]  Host-only network: host $hostIp, VM gets $dhcpLower - $dhcpUpper via DHCP"

if ($NonInteractive) {
    exit 0
}

# 10) Open VirtualBox with the new VM selected
Start-Process (Join-Path $vmDir "$vmname.vbox")
Write-Host "[OK]  Please complete the Beckhoff RT-Linux installation inside VirtualBox."
Write-Host ""
Read-Host "Press Enter to exit"

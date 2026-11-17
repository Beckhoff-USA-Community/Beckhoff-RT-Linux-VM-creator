# Beckhoff RT Linux® VM Creator

Automated PowerShell script to create and configure a Beckhoff RT Linux® virtual machine in VirtualBox with optimal settings.

## Intended Use

A virtual machine cannot provide the determinism or reliability that TwinCAT Runtime for Linux® depends on, so a VM created with this script is **not supported for any kind of production use**. It is well suited for:

- **Training**: Learn Beckhoff RT Linux® and TwinCAT Runtime for Linux® without dedicated hardware
- **CI/CD testing**: Spin up disposable VMs to build and test TwinCAT projects in an automated pipeline
- **Evaluation**: Try out Beckhoff RT Linux® before committing to hardware

For production applications, run TwinCAT Runtime for Linux® on supported Beckhoff hardware.

## Features

- **Automated VM Creation**: Creates a fully configured VirtualBox VM with a single command
- **Dual Network Setup**: NAT for internet access + Host-Only network for direct VM communication
- **Interactive Configuration**: GUI dialogs for selecting image files and storage locations, console prompts for CPU count, memory and disk sizes
- **Optimized Settings**: Pre-configured with EFI firmware, VMSVGA graphics, and appropriate resource allocation
- **Dual Disk Architecture**: Separate installer and runtime disks for clean installation workflow

## Prerequisites

- **Windows host**: The script uses Windows dialogs and system queries, so it runs on Windows only
- **VirtualBox**: Download and install from [virtualbox.org](https://www.virtualbox.org/wiki/Downloads)
  - Tested with VirtualBox 7.2. Other 7.x releases are expected to work but have not been verified.
- **Beckhoff RT Linux® Image**: Download the [Beckhoff RT Linux® image](https://www.beckhoff.com/en-us/support/download-finder/search-result/?download_group=992954948&download_item=992954970) (`.img` file)
  - Tested with `Beckhoff-RT-Linux-440542-installer-amd64.img`. Other image versions are expected to work but have not been verified.
- **PowerShell**: Windows PowerShell 5.1 (built into Windows) or [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows). Creating a host-only network adapter may trigger a UAC prompt.

## PowerShell Setup

Before running the script for the first time, you need to configure PowerShell execution policy:

### 1. Set Execution Policy

Open PowerShell and run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

This allows locally created scripts to run, and downloaded scripts once they are unblocked (next step).

### 2. Unblock the Script

If you downloaded the script from the internet, Windows may block it. Unblock it with:

```powershell
Unblock-File -Path ".\Create-TcRTLinuxVM.ps1"
```

## Usage

### Basic Usage (Interactive)

Run the script with just a VM name, and select files/folders through GUI dialogs. The script then asks for the number of CPUs, the amount of memory and the disk sizes. Press Enter at each prompt to accept the default.

```powershell
.\Create-TcRTLinuxVM.ps1 -vmname "MyRTLinuxVM"
```

### Advanced Usage (Full Parameters)

Specify all parameters to run without interactive prompts:

```powershell
.\Create-TcRTLinuxVM.ps1 `
    -vmname "MyRTLinuxVM" `
    -linuxImageFile "C:\Downloads\beckhoff-rtlinux.img" `
    -vmStoragePath "D:\VirtualMachines" `
    -virtualBoxPath "C:\Program Files\Oracle\VirtualBox" `
    -cpus 4 `
    -memoryMB 4096 `
    -installerDiskSizeGB 8 `
    -runtimeDiskSizeGB 32
```

Any sizing parameter you leave out is asked for interactively.

### Unattended Usage (CI/CD)

Add `-NonInteractive` to run without any dialogs or prompts. Missing paths become errors, sizing defaults are used as-is, VirtualBox is not opened, and the script exits with a non-zero code on failure:

```powershell
.\Create-TcRTLinuxVM.ps1 `
    -vmname "CI-RTLinux" `
    -linuxImageFile "C:\images\Beckhoff-RT-Linux-440542-installer-amd64.img" `
    -vmStoragePath "D:\VirtualMachines" `
    -NonInteractive
```

Full parameter help is also available with `Get-Help .\Create-TcRTLinuxVM.ps1 -Detailed`.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `vmname` | Yes | - | Name for your virtual machine |
| `linuxImageFile` | No | Interactive | Path to Beckhoff RT Linux® `.iso` or `.img` file |
| `vmStoragePath` | No | VirtualBox default | Directory where VM files will be stored |
| `virtualBoxPath` | No | `C:\Program Files\Oracle\VirtualBox` | VirtualBox installation directory |
| `cpus` | No | 4 (prompted) | Number of virtual CPUs |
| `memoryMB` | No | 4096 (prompted) | Amount of RAM in MB |
| `installerDiskSizeGB` | No | 8 (prompted) | Installer disk size in GiB. Must be at least the size of the image file |
| `runtimeDiskSizeGB` | No | 32 (prompted) | Runtime (OS) disk size in GiB. Dynamically allocated, so only used space is consumed on the host |
| `hostOnlySubnet` | No | `192.168.42` | First three octets of the host-only network. Change this if it collides with your LAN |
| `NonInteractive` | No | Off | Never prompt or open VirtualBox. For CI/CD use |

## What the Script Does

The script automatically performs the following steps. If any step fails, the VM and any disks created so far are removed.

### 1. VM Creation
- Creates a Debian 64-bit VM with EFI firmware
- Allocates the requested number of CPU cores (default 4) and RAM (default 4096 MB)
- Configures VMSVGA graphics controller with 128MB VRAM

### 2. Network Configuration
- **Adapter 1 (NAT)**: Provides internet access to the VM
- **Adapter 2 (Host-Only)**: Enables direct host-to-VM communication (defaults shown, change with `-hostOnlySubnet`)
  - Network: 192.168.42.0/24
  - Host IP: 192.168.42.1
  - DHCP Range: 192.168.42.11 - 192.168.42.99
  - DHCP Server: 192.168.42.2
  - An existing host-only adapter with the host IP is reused. Otherwise a new adapter is created; existing adapters are never reconfigured.

### 3. Storage Setup
- **Installer Disk (Port 1)**: Converts your image to VDI format, resized to the requested size (default 8 GiB)
- **Runtime Disk (Port 0)**: Creates a dynamically allocated VHD disk for the OS installation (default 32 GiB)
- Attaches both disks to a SATA controller

### 4. VM Launch
- Automatically opens VirtualBox with your new VM (skipped with `-NonInteractive`)
- Ready for you to complete the Beckhoff RT Linux® installation

## Network Details

After installation, your VM will have two network interfaces:

- **eth0 (NAT)**: Automatically configured for internet access
- **eth1 (Host-Only)**: For communication with host machine
  - VM will receive IP via DHCP (typically 192.168.42.11)
  - Host accessible at 192.168.42.1

You can SSH or connect to your VM using its Host-Only IP address from your Windows host.

## Troubleshooting

### "VirtualBox not found" Error
Ensure VirtualBox is installed or specify the correct path with `-virtualBoxPath`

### Script Won't Run
1. Check execution policy: `Get-ExecutionPolicy -Scope CurrentUser`
2. If restricted, run: `Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser`
3. Unblock the script: `Unblock-File -Path ".\Create-TcRTLinuxVM.ps1"`

### Multiple Host-Only Networks Created
The script reuses an existing host-only adapter that already has the host IP (192.168.42.1 by default) and creates a new one otherwise. If you see unused adapters, you can delete them in VirtualBox Network Manager.

### "A VM named ... already exists"
VM names must be unique in VirtualBox. Pick a different name, or remove the old VM (and its folder) first.

### Host-Only Subnet Conflicts With My Network
If 192.168.42.0/24 is already used by your LAN or VPN, pass a different subnet, for example `-hostOnlySubnet 192.168.57`.

### VM Won't Boot
Ensure your system supports virtualization and that it's enabled in your BIOS/UEFI settings.

## Post-Installation

After the VM boots and you complete the [Beckhoff RT Linux® installation](https://infosys.beckhoff.com/content/1033/beckhoff_rt_linux/17350491915.html?id=4863220882098761085), follow the [first steps](https://infosys.beckhoff.com/content/1033/beckhoff_rt_linux/17350315403.html?id=1118996582036379752).

## Support and Contributing

This is a community project and is not covered by Beckhoff support. Please report problems or suggest improvements through GitHub issues and pull requests.

## License

This project is licensed under the BSD Zero Clause License (0BSD). See the [LICENSE](LICENSE) file for details.

## Disclaimer

All sample code provided by Beckhoff Automation LLC are for illustrative purposes only and are provided "as is" and without any warranties, express or implied. Actual implementations in applications will vary significantly. Beckhoff Automation LLC shall have no liability for, and does not waive any rights in relation to, any code samples that it provides or the use of such code samples for any purpose.

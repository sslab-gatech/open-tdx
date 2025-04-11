# OpenTDX: Emulating TDX Machine

## Introduction

OpenTDX is a TDX emulation framework on KVM, which runs TDX host kernel in L1 VM, and TDX guest kernel (i.e., TD VM) in L2 VM.
With OpenTDX, researchers (and developers) can customize the TDX module, test a sotfware stack of TDX, or just play with TDX without a real TDX machine.
Based on KVM, OpenTDX implements key features of TDX including Intel SMX, MKTME, SEAM.

## Directory Structure

```
open-tdx/
  |- linux-l0      : Linux source for LO (i.e., baremetal)
  |- qemu-l0       : QEMU source to launch L1 VM (i.e., TDX host)
  |- seabios       : Seabios source (i.e., BIOS of L1 VM)
  |- seam-loader   : np-seamldr/p-seamldr source loaded by Seabios
  |- tdx-module    : TDX module source
  |
  |- linux-l1      : Linux source for L1 (i.e., TDX host)
  |- qemu-l1       : QEMU source to launch L2 VM (i.e., TDX guest)
  |- edk2          : TDVF source (i.e., BIOS of L2 VM)
  |
  `- linux-l2      : Linux source for L2 (i.e., TDX guest, TD VM)
```

## Setup & Usage
Scripts are tested on Ubuntu 22.04.

**Caution: running `setup.sh` installs a baremetal kernel. To avoid installing new kernel, you should manually modify KVM based on your kernel's source code.*

### Preparation
```
./setup.sh # This updates git submodules, builds sources, and creates VM images
```
After `setup.sh` is done, please reboot using newly installed kernel, which can be selected in GRUB menu.
Then, reload `kvm-intel` module with `open_tdx` parameter enabled.
```
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel open_tdx=1 # This may require loading other dependent modules as well
```

### Launching TD
```
./launch-opentdx.sh # This will launch L1 VM (i.e., TDX host)
ssh -i images/l1.id_rsa -p 10032 root@localhost # ssh into L1 VM

(l1-vm) $ ./scripts/load-kvm.sh
(l1-vm) $ ./scripts/launch-td.sh
```

### SSH into TD VM
```
ssh -i images/l2.id_rsa -p 10033 root@localhost
```

Running `dmesg | grep -i tdx` inside TD VM will show following messages:
```
[    0.000000] tdx: Guest detected
[    0.000000] tdx: Attributes: SEPT_VE_DISABLE
[    0.000000] tdx: TD_CTLS: PENDING_VE_DISABLE ENUM_TOPOLOGY
[    6.497421] process: using TDX aware idle routine
[    6.497421] Memory Encryption Features active: Intel TDX
```

### Customizing TDX Module
We provide scripts for building TDX module. After modifying TDX module source, one can build it with following commands (it needs docker):
```
cd tdx-module
OPENTDX=1 ./build.sh # This will output libtdx.so & libtdx.so.sigstruct under bin/debug
```
As environment variables you can give
- `OPENTDX`: required to build a TDX module that runs on OpenTDX
- `DEBUGTRACE`: enable logging in TDX module
- `UNSTRIPPED`: output debug symbols under `bin/debug.unstripped` directory (used for loading symbol file in GDB)

## Other Tips
OpenTDX contains various helper scripts for implementations and debuggins.

### Adding New Features to KVM
After `setup.sh` is done, `kvm-l0`, `kvm-l1` directories are produced. Developers can directly build `kvm` modules only by running `build.sh` scripts in such directories, and reloads such modules only.

### Manuals of scripts
- `common.sh`
```
  Usage: ./common.sh [-t <target>] [-l <vm_level>] [-d <distribution>] [-s <image_size>]
Options:
  -t <target>                  Specify which target to run
                               - options: qemu, image, seabios, ovmf, tdx-module,
                                 seam-loader, linux, kernel, initrd, kvm, vm
  -l <vm_level>                Specify the VM nested level
                               - options: l0, l1
  -d <distribution>    Specify the distribution version of Debian
                               - options: bookworm
  -s <image_size>              Specify the image size (MB)
                               - examples: 32768 (32G)
```
- `launch-opentdx.h`
```
Usage: ./launch-opentdx.sh [-m <mem>] [-s <smp>] [-p <ssh_port>]
Options:
  -m <mem>              Specify the memory size
                               - default: 8g
  -s <smp>              Specify the SMP
                               - default: 8
  -p <ssh_port>         Specify the ssh port for l1/l2
                         port for l2 will be <ssh_port> + 1
                               - default: 10032
```
- `scripts/launch-td.h` in L1 VM
```
Usage: ./scripts/launch-td.sh [-m <mem>] [-s <smp>]
Options:
  -m <mem>              Specify the memory size
                               - default: 1g
  -s <smp>              Specify the SMP
                               - default: 1
```

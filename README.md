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
OPENTDX=1 MAXGPA=<max-gpa> SHAREDGPA=<shared-gpa> ./build.sh # This will output libtdx.so & libtdx.so.sigstruct under bin/debug
```
As environment variables you can give
- `OPENTDX`: required to build a TDX module that runs on OpenTDX
- `MAXGPA`: maximum GPA bits of L1 VM (you can get by running `./common.sh -t phy`)
- `SHAREDGPA`: `MAXGPA - 1`
- `DEBUGTRACE`: enable logging in TDX module
- `UNSTRIPPED`: output debug symbols under `bin/debug.unstripped` directory (used for loading symbol file in GDB)

## Other Tips
OpenTDX contains various helper scripts for implementations and debuggings.

### Attaching GDB to L1 KVM and TDX module

L1 KVM and TDX module can be debugged through QEMU GDB interface. Debug port is set default to `1234`.

Attach to the L1 VM as follows:
```
DEBUG=1 ./launch-opentdx.sh # This launches QEMU in debug mode

(another terminal) $ cd linux-l1
(another terminal) $ gdb ./vmlinux # linux-l1/scripts/gdb/vmlinux-gdb.py should be loaded here

(gdb) target remote:1234 # This attaches GDB to the L1 VM
(gdb) c # Once you attach, boot the L1 kernel
```

Once the GDB is attached and L1 kernel is booted, follow the steps below to load L1 KVM and break at the entrypoint of TDX module:
```
ssh -i images/l1.id_rsa -p 10032 root@localhost # ssh into L1 VM
(l1-vm) $ ./scripts/load-kvm.sh

# Ctrl-C in gdb to obtain terminal
(gdb) lx-symbols ../kvm-l1 # This will load debug symbols of L1 KVM
(gdb) b __seamcall # Set breakpoint at seamcall macro
(gdb) c # Continue

(l1-vm) $ ./scripts/launch-td.sh # GDB will break at __seamcall

(gdb at __seamcall) d 1 # Delete breakpoint
(gdb at __seamcall) layout asm
(gdb at __seamcall) si # Step multiple times until executing the exact seamcall instruction
...
(gdb at __seamcall) si # Execute the seamcall instruction finally
```

Executing `seamcall` above will step into the TDX module's entrypoint. The entrypoint address (i.e., `RIP` value right after the execution) will be like `0xffffXXXX000YYYYY`, where `XXXX` changes every time as TDX module applys ASLR, and `YYYYY` depends on the source code and toolchain.

We have to load the symbol file at the base address of `text` section, which should be `0xffffXXXX00000ZZZ` where `ZZZ` can be retrieved from `readelf -S tdx-module/bin/debug/libtdx.so`. For example, in my trial, the entrypoint address was `0xffffa73800034424` and `text` base address was `0xffffa738000001a0`.

Once you retrieve the available information, you can load the symbol file as follows:
```
(gdb at entrypoint) add-symbol-file ../tdx-module/bin/debug/libtdx.so 0xffffXXXX00000ZZZ # And type 'y' to the prompt
```

You can also load symbol file with source code information using `../tdx-module/bin/debug.unstrippted/libtdx.so` (after building it as explained in [Customizing TDX Module](#customizing-tdx-module)).


### Adding New Features to KVM
After `setup.sh` is done, `kvm-l0`, `kvm-l1` directories are produced. Developers can directly build `kvm` modules only by running `build.sh` scripts in such directories, and reload them only.
Host modules (i.e., `kvm-l0`) can be loaded directly.
Guest modules (i.e., `kvm-l1`) are automatically passthroughed in the L1 VM and loaded using `./scripts/load-kvm.sh` in the VM.

### Manuals of scripts
- `common.sh`
```
  Usage: ./common.sh [-t <target>] [-l <vm_level>] [-d <distribution>] [-s <image_size>]
Options:
  -t <target>                  Specify which target to run
                               - options: qemu, image, seabios, ovmf, tdx-module,
                                 seam-loader, linux, kernel, initrd, kvm, vm, phy
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



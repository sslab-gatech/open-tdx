#!/bin/bash -e

QEMU=$PWD/build-qemu-l1/qemu-system-x86_64
OVMF=$PWD/edk2/Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd

KERNEL=linux-l2/arch/x86/boot/bzImage
INITRD=linux-l2/initrd.img-l2

IMG=images/l2.img

cmdline="console=ttyS0 root=/dev/sda rw"

run_qemu()
{
    local mem=$1
    local smp=$2
    local ssh_port=10032

    qemu_str=""
    qemu_str+="${QEMU} -cpu host -enable-kvm \\"
    qemu_str+="-m ${mem} -smp ${smp} \\"
    qemu_str+="-bios ${OVMF} \\"

    qemu_str+="-object tdx-guest,id=tdx \\"
    qemu_str+="-machine q35,kernel-irqchip=split,confidential-guest-support=tdx \\"

    qemu_str+="-device e1000,netdev=net0 \\"
    qemu_str+="-netdev user,id=net0,host=10.0.2.10,hostfwd=tcp::${ssh_port}-:22 \\"

    qemu_str+="-drive format=raw,file=${IMG} \\"

    qemu_str+="-kernel ${KERNEL} -initrd ${INITRD} -append \"${cmdline}\" \\"
    qemu_str+="-nographic"

    eval ${qemu_str}
}

# Function to show usage information
usage() {
  echo "Usage: $0 [-m <mem>] [-s <smp>]" 1>&2
  echo "Options:" 1>&2
  echo "  -m <mem>              Specify the memory size" 1>&2
  echo "                               - default: 1g" 1>&2
  echo "  -s <smp>              Specify the SMP" >&2
  echo "                               - default: 1" 1>&2
  exit 1
}

mem=1g
smp=1

while getopts ":hm:s:p:" opt; do
    case $opt in
        h)
            usage
            ;;
        m)
            mem=$OPTARG
            echo "Memory: ${mem}"
            ;;
        s)
            smp=$OPTARG
            echo "SMP: ${smp}"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

shift $((OPTIND -1))

run_qemu ${mem} ${smp}

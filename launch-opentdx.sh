#!/bin/bash -e

QEMU=$PWD/qemu-l0/build/qemu-system-x86_64
SEABIOS=$PWD/seabios/out/bios.bin

NPSEAMLDR=$PWD/seam-loader/seam-loader-main-1.5/np-seam-loader/seamldr_src/Projects/Server/Emr/Seamldr/output/ENG_TR_O1/EMR_NP_SEAMLDR_ENG_TR_O1.DBG.bin

TDXMODULE=$PWD/tdx-module/bin/debug/libtdx.so
TDXMODULE_SIGSTRUCT=${TDXMODULE}.sigstruct

KERNEL=linux-l1/arch/x86/boot/bzImage
INITRD=linux-l1/initrd.img-l1

IMG=images/l1.img
QEMU_L1=qemu-l1
KVM_L1=kvm-l1
LINUX_L2=linux-l2
EDK2=edk2
SCRIPTS=scripts

run_qemu()
{
    local mem=$1
    local smp=$2
    local ssh_port=$3
    local debug_port=$4

    nested_ssh_port=$((ssh_port + 1))
    nested_debug_port=$((debug_port + 1))


    cmdline="console=ttyS0 root=/dev/sda rw earlyprintk=serial net.ifnames=0 nohibernate debug"
    gpu_str=""

    [ ! -z ${GPU} ] && {
        bdfs=($(lspci | grep -i nvidia | cut -d' ' -f1))
        [ ${#bdfs[@]} -eq 0 ] && {
            echo "[-] No GPU found"
            exit 1
        }

        vdids=$(lspci -nn | grep -i nvidia | sed -n 's/.*\[\(....:....\)\].*/\1/p' | paste -sd,)

        cmdline+=" intel_iommu=on iommu=on"
        cmdline+=" vfio-pci.ids=${vdids}"

        gpu_str="-device intel-iommu,intremap=on,caching-mode=on \\"
        gpu_str+="-device pci-bridge,id=bridge0,chassis_nr=1 \\"
        for bdf in ${bdfs[@]}
        do
            gpu_str+="-device vfio-pci,bus=bridge0,host=${bdf} \\"
        done
    }

    qemu_str=""
    qemu_str+="${QEMU} -cpu host -machine q35,kernel_irqchip=split -enable-kvm \\"
    qemu_str+="-m ${mem} -smp ${smp} \\"
    qemu_str+="-bios ${SEABIOS} \\"

    qemu_str+="-fw_cfg opt/opentdx.npseamldr,file=${NPSEAMLDR} \\"
    qemu_str+="-fw_cfg opt/opentdx.tdx_module,file=${TDXMODULE} \\"
    qemu_str+="-fw_cfg opt/opentdx.seam_sigstruct,file=${TDXMODULE_SIGSTRUCT} \\"

    qemu_str+="-drive format=raw,file=${IMG} \\"

    qemu_str+="-device virtio-net-pci,netdev=net0 \\"
    qemu_str+="-netdev user,id=net0,host=10.0.2.10,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${nested_ssh_port}-:10032,hostfwd=tcp::${nested_debug_port}-:1234 \\"

    qemu_str+="-virtfs local,path=${QEMU_L1},mount_tag=${QEMU_L1},security_model=passthrough,id=${QEMU_L1} \\"
    qemu_str+="-virtfs local,path=${KVM_L1},mount_tag=${KVM_L1},security_model=passthrough,id=${KVM_L1} \\"
    qemu_str+="-virtfs local,path=${LINUX_L2},mount_tag=${LINUX_L2},security_model=passthrough,id=${LINUX_L2} \\"
    qemu_str+="-virtfs local,path=${SCRIPTS},mount_tag=${SCRIPTS},security_model=passthrough,id=${SCRIPTS} \\"
    qemu_str+="-virtfs local,path=${EDK2},mount_tag=${EDK2},security_model=passthrough,id=${EDK2} \\"

    qemu_str+=${gpu_str}

    qemu_str+="-kernel ${KERNEL} -initrd ${INITRD} -append \"${cmdline}\" \\"

    [ ! -z ${DEBUG} ] && {
        qemu_str+="-S -gdb tcp::${debug_port} \\"
    }

    qemu_str+="-nographic"

    eval sudo ${qemu_str}
}

# Function to show usage information
usage() {
  echo "Usage: $0 [-m <mem>] [-s <smp>] [-p <ssh_port>] [-d <debug_port>]" 1>&2
  echo "Options:" 1>&2
  echo "  -m <mem>              Specify the memory size" 1>&2
  echo "                               - default: 8g" 1>&2
  echo "  -s <smp>              Specify the SMP" >&2
  echo "                               - default: 8" 1>&2
  echo "  -p <ssh_port>         Specify the ssh port for l1/l2" 1>&2
  echo "                         port for l2 will be <ssh_port> + 1" 1>&2
  echo "                               - default: 10032" 1>&2
  echo "  -d <debug_port>       Specify the debug port for l1/l2" 1>&2
  echo "                         port for l2 will be <debug_port> + 1" 1>&2
  echo "                               - default: 1234" 1>&2
  exit 1
}

mem=8g
smp=8
ssh_port=10032
debug_port=1234

while getopts ":hm:s:p:d:" opt; do
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
        p)
            ssh_port=$OPTARG
            echo "SSH Port: ${ssh_port}"
            ;;
        d)
            debug_port=$OPTARG
            echo "Debug Port: ${debug_port}"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

shift $((OPTIND -1))

run_qemu ${mem} ${smp} ${ssh_port} ${debug_port}

#!/bin/bash -e

run_cmd()
{
    echo "$*"

    eval "$*" || {
        echo "Error: $*"
        exit 1
    }
}

check_argument()
{
    opt=$1
    arg=$2
    val=$3

    if [ -z ${val} ]
    then
        echo "Error: Please provide ${opt} <${arg}>"
        exit 1
    fi
}

run_mount()
{
    local tmp=$1
    local img=$2

    [ -d ${tmp} ] && {
        echo "Error: ${tmp} already exist, please remove it"
        exit 1
    }
    mkdir -p ${tmp}

    run_cmd sudo mount images/${img}.img ${tmp}
    sleep 1
}

run_umount()
{
    local tmp=$1

    run_cmd sudo umount ${tmp}
    rm -rf ${tmp}
}

run_chroot()
{
    root=$1
    script=$2
    nocheck=$3

    sudo chroot ${root} /bin/bash -c """
set -ex
${script}
exit
"""
    if [ -z $nocheck ] && [ $? -ne 0 ]; then
        echo "Error: chroot failed"
        exit 1
    fi
}

fix_phy_bits()
{
    [[ "$(ls -A seabios)" || "$(ls -A tdx-module)" || "$(ls -A linux-l0)" || "$(ls -A linux-l1)" ]] || {
        echo "Error: submodules not fetched"
        exit 1
    }

    # phybits=$(lscpu | grep "Address sizes" | awk '{print $3}')
    phybits=39
    maxgpa=$(( phybits-1 ))
    # When phybits is small, mktmebits should be reduced to avoid occupying real GPA
    mktmebits=$(( (phybits-36<6) ? phybits-36 : 6))

    if [ $phybits -le 36 ];
    then
        echo "Error: this machine has physical address bits (${phybits}) lower than 36"
        exit 1
    fi

    if [ $mktmebits -ne 6 ];
    then
        sed -i "253s/andl \$0xf/movl \$0x${mktmebits}/" seabios/src/fw/tdx.c
        sed -i "14s/6ULL/${mktmebits}ULL/" linux-l0/arch/x86/kvm/vmx/mktme.h
    fi

    sed -i "104s/46/${phybits}/g" tdx-module/src/common/helpers/helpers.h
    sed -i "113s/45/${maxgpa}/g" tdx-module/src/common/helpers/helpers.h
    sed -i "113s/46/${phybits}/g" tdx-module/src/common/helpers/helpers.h
    sed -i "128s/45/${maxgpa}/g" tdx-module/src/common/helpers/helpers.h
    sed -i "615s/46/${phybits}/g" tdx-module/src/common/x86_defs/x86_defs.h

    sed -i "43s/45/${maxgpa}/g" linux-l1/arch/x86/kvm/vmx/tdx.c
}

build_qemu()
{
    local vm_level=$1
    local distribution=$2

    check_argument "-l" "vm_level" ${vm_level}
    check_argument "-d" "distribution" ${distribution}

    if [ ${vm_level} = "l2" ];
    then
        echo "Error: build_qemu not supported for ${vm_level}"
        exit 1
    fi

    NUM_CORES=$(nproc)
    MAX_CORES=$(($NUM_CORES - 1))

    [ "$(ls -A qemu-${vm_level})" ] || {
        echo "Error: qemu-${vm_level} not fetched"
        exit 1
    }

    if [ ${vm_level} = "l0" ];
    then
        sudo sed -i 's/# deb-src/deb-src/' /etc/apt/sources.list

        run_cmd sudo apt update

        export DEBIAN_FRONTEND=noninteractive
        run_cmd sudo apt install -y build-essential git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev
        run_cmd sudo -E apt build-dep -y qemu
        run_cmd sudo apt install -y libaio-dev libbluetooth-dev libbrlapi-dev libbz2-dev
        run_cmd sudo apt install -y libsasl2-dev libsdl1.2-dev libseccomp-dev libsnappy-dev libssh2-1-dev
        run_cmd sudo apt install -y python3 python-is-python3 python3-venv

        mkdir -p qemu-${vm_level}/build
        pushd qemu-${vm_level}/build >/dev/null
        run_cmd ../configure --target-list=x86_64-softmmu --enable-kvm -enable-slirp --disable-werror
        make -j ${MAX_CORES}
        popd >/dev/null
    else # l1
        [ -f images/${vm_level}.img ] || {
            echo "Error: ${vm_level}.img not existing"
            exit 1
        }

        tmp=$(realpath tmp)
        run_mount ${tmp} ${vm_level}

        run_cmd sudo mkdir ${tmp}/root/qemu-${vm_level}
        run_cmd sudo mkdir ${tmp}/root/build-qemu-${vm_level}

        run_cmd sudo mount --bind qemu-${vm_level} ${tmp}/root/qemu-${vm_level}

        run_chroot ${tmp} """
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
echo 'deb-src https://deb.debian.org/debian ${distribution} main non-free-firmware' >> /etc/apt/sources.list

apt update

export DEBIAN_FRONTEND=noninteractive

apt install -y build-essential git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev
apt build-dep -y qemu
apt install -y libaio-dev libbluetooth-dev libbrlapi-dev libbz2-dev
apt install -y libsasl2-dev libsdl1.2-dev libseccomp-dev libsnappy-dev libssh2-1-dev
apt install -y python3 python-is-python3 python3-venv

cd /root/build-qemu-${vm_level}
../qemu-${vm_level}/configure --target-list=x86_64-softmmu --enable-kvm --enable-slirp --disable-werror
make -j ${MAX_CORES}
"""

        run_cmd sudo umount ${tmp}/root/qemu-${vm_level}
        run_cmd sudo rm -rf ${tmp}/root/qemu-${vm_level}
        run_umount ${tmp}
    fi
}

build_image()
{
    local vm_level=$1
    local distribution=$2
    local size=$3

    check_argument "-l" "vm_level" ${vm_level}
    check_argument "-d" "distribution" ${distribution}
    check_argument "-s" "image_size" ${size}

    run_cmd sudo apt install -y debootstrap

    if [ ${vm_level} = "l0" ]
    then
        echo "Error: build_image not supported for ${vm_level}"
        exit 1
    fi

    pushd images > /dev/null

    run_cmd chmod +x create-image.sh

    echo "[+] Build ${image} image ..."

    run_cmd ./create-image.sh -d ${distribution} -s ${size}
    run_cmd mv ${distribution}.img ${vm_level}.img
    run_cmd mv ${distribution}.id_rsa ${vm_level}.id_rsa
    run_cmd mv ${distribution}.id_rsa.pub ${vm_level}.id_rsa.pub

    popd > /dev/null
}

finalize_vms()
{
    if [[ ! -f images/l1.img || ! -f images/l2.img ]]
    then
        echo "Error: images/l1.img,l2.img not found"
        exit 1
    fi

    tmp=$(realpath tmp)
    run_mount ${tmp} l2

    sudo sed -i 's/eth0/enp0s1/g' ${tmp}/etc/network/interfaces

    run_umount ${tmp}

    run_mount ${tmp} l1

    run_cmd sudo mkdir -p ${tmp}/root/images
    run_cmd sudo cp images/l2.img ${tmp}/root/images/

    fstab=""
    for dir in "qemu-l1" "kvm-l1" "linux-l2" "edk2" "scripts"
    do
        fstab+="${dir} /root/${dir} 9p trans=virtio,version=9p2000.L 0 0\n"
    done

    echo -ne ${fstab} | sudo tee -a ${tmp}/etc/fstab

    run_umount ${tmp}
}

build_seabios()
{
    [ "$(ls -A seabios)" ] || {
        echo "Error: seabios not fetched"
        exit 1
    }

    run_cmd sudo apt install -y build-essential python3 python-is-python3

    pushd seabios >/dev/null

    run_cmd make defconfig
    run_cmd ./config.sh
    run_cmd make -j

    popd >/dev/null
}

build_tdx_module()
{
    [ "$(ls -A tdx-module)" ] || {
        echo "Error: tdx-module not fetched"
        exit 1
    }

    run_cmd sudo apt install -y python3-dev

    pushd tdx-module >/dev/null
    run_cmd "OPENTDX=1 ./build.sh"
    popd >/dev/null
}

build_seam_loader()
{
    [ "$(ls -A seam-loader)" ] || {
        echo "Error: seam-loader not fetched"
        exit 1
    }

    echo "build seam_loader"
}

build_ovmf()
{
    [ "$(ls -A edk2)" ] || {
        echo "Error: edk2 not existing"
    }

    run_cmd sudo apt install -y nasm iasl python3 python-is-python3 python3-venv uuid-dev

    pushd edk2 >/dev/null
    run_cmd git submodule update --init --recursive

    run_cmd make -C BaseTools
    . ./edksetup.sh

    sed -i 's/= IA32/= X64/g' Conf/target.txt
    sed -i 's/= VS2022/= GCC5/g' Conf/target.txt

    run_cmd build -v -t GCC5 -DBUILD_TARGETS=RELEASE -DDEBUG_ON_SERIAL_PORT=FALSE -a X64 -p OvmfPkg/OvmfPkgX64.dsc -Y COMPILE_INFO -y .dummy -b RELEASE # I don't know -y option

    popd >/dev/null
}


build_linux()
{
    local vm_level=$1

    check_argument "-l" "vm_level" ${vm_level}

    NUM_CORES=$(nproc)
    MAX_CORES=$(($NUM_CORES - 1))

    run_cmd sudo apt install -y git fakeroot build-essential ncurses-dev xz-utils libssl-dev bc flex \
                                libelf-dev bison cpio zstd

    [ "$(ls -A linux-${vm_level})" ] || {
        echo "Error: linux-${vm_level} not existing"
        exit 1
    }

    MAKE="make -C linux-${vm_level} -j${MAX_CORES} LOCALVERSION="

    run_cmd ${MAKE} distclean

    pushd linux-${vm_level} > /dev/null

    if [ ${vm_level} = "l0" ];
    then
        [ -f /boot/config-$(uname -r) ] || {
            echo "Error: /boot/config-$(uname -r) not found"
            exit 1
        }
        run_cmd cp -f /boot/config-$(uname -r) .config

        ./scripts/config --enable CONFIG_EXPERT
        ./scripts/config --enable CONFIG_KVM_SW_PROTECTED_VM
        ./scripts/config --enable CONFIG_KVM_GENERIC_PRIVATE_MEM

        ./scripts/config --disable SYSTEM_TRUSTED_KEYS
        ./scripts/config --disable SYSTEM_REVOCATION_KEYS
    else # l1, l2
        run_cmd make defconfig
        run_cmd make kvm_guest.config

        ./scripts/config --enable CONFIG_CONFIGFS_FS
        ./scripts/config --module CONFIG_KVM
        ./scripts/config --module CONFIG_KVM_INTEL

        # For TDX host
        ./scripts/config --enable CONFIG_EXPERT
        ./scripts/config --enable CONFIG_KVM_SW_PROTECTED_VM
        ./scripts/config --enable CONFIG_KVM_GENERIC_PRIVATE_MEM
        ./scripts/config --enable CONFIG_X86_SGX_KVM

        ./scripts/config --enable CONFIG_X86_X2APIC
        ./scripts/config --enable CONFIG_CMA
        ./scripts/config --disable CONFIG_KEXEC
        ./scripts/config --enable CONFIG_CONTIG_ALLOC
        ./scripts/config --enable CONFIG_ARCH_KEEP_MEMBLOCK
        ./scripts/config --enable CONFIG_INTEL_TDX_HOST
        ./scripts/config --enable CONFIG_KVM_INTEL_TDX
        
        ./scripts/config --disable CONFIG_KSM
        ./scripts/config --disable CONFIG_EISA
        ./scripts/config --enable CONFIG_BLK_MQ_VIRTIO
        ./scripts/config --enable CONFIG_VIRTIO_NET
        ./scripts/config --enable CONFIG_IRQ_REMAP

        # Huge page for optimizing TD page accepting
        ./scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE

        # For TDX guest
        ./scripts/config --enable CONFIG_SGX
        ./scripts/config --enable CONFIG_INTEL_TDX_GUEST
        ./scripts/config --enable CONFIG_VIRT_DRIVERS
        ./scripts/config --module CONFIG_TDX_GUEST_DRIVER
        ./scripts/config --disable CONFIG_HYPERV


        # For debugging
        ./scripts/config --enable CONFIG_DEBUG_INFO_DWARF5
        ./scripts/config --enable CONFIG_DEBUG_INFO
        ./scripts/config --disable CONFIG_RANDOMIZE_BASE
        ./scripts/config --enable CONFIG_GDB_SCRIPTS
    fi

    popd > /dev/null

    run_cmd ${MAKE} olddefconfig

    # TODO: Need to check configs are correctly set

    echo "[+] Build linux kernel..."
    run_cmd ${MAKE}
}

install_kernel()
{
    local vm_level=$1

    check_argument "-l" "vm_level" ${vm_level}

    run_cmd sudo apt install -y rsync grub2

    NUM_CORES=$(nproc)
    MAX_CORES=$(($NUM_CORES - 1))

    [ -f linux-${vm_level}/arch/x86/boot/bzImage ] || {
        echo "Error: linux-${vm_level} not built"
        exit 1
    }

    version=$(cat linux-${vm_level}/include/config/kernel.release)

    if [ ${vm_level} = "l0" ];
    then
        pushd linux-${vm_level} >/dev/null

        run_cmd sudo make -j${MAX_CORES} INSTALL_MOD_STRIP=1 modules_install
        run_cmd sudo make -j${MAX_CORES} headers_install
        run_cmd sudo make install

        popd >/dev/null

        # TODO grub
        sudo sed -i "s/GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/g" /etc/default/grub
        sudo sed -i "s/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/g" /etc/default/grub
        run_cmd sudo update-grub
    else # l1, l2
        [ -f images/${vm_level}.img ] || {
            echo "Error: images/${vm_level}.img not found"
            exit 1
        }

        tmp=$(realpath tmp)
        run_mount ${tmp} ${vm_level}

        pushd linux-${vm_level} > /dev/null

        run_cmd sudo rm -rf ${tmp}/usr/src/linux-headers-${version}
        [ -d ${tmp}/usr/src/linux-headers-${version}/arch/x86 ] || {
            run_cmd sudo mkdir -p ${tmp}/usr/src/linux-headers-${version}/arch/x86
        }
        [ -d ${tmp}/usr/src/linux-headers-${version}/arch/x86 ] && {
            run_cmd sudo cp arch/x86/Makefile* ${tmp}/usr/src/linux-headers-${version}/arch/x86
            run_cmd sudo cp -r arch/x86/include ${tmp}/usr/src/linux-headers-${version}/arch/x86
        }
        run_cmd sudo cp -r include ${tmp}/usr/src/linux-headers-${version}
        run_cmd sudo cp -r scripts ${tmp}/usr/src/linux-headers-${version}

        [ -d ${tmp}/usr/src/linux-headers-${version}/tools/objtool ] || {
            run_cmd sudo mkdir -p ${tmp}/usr/src/linux-headers-${version}/tools/objtool
        }

        [ -d ${tmp}/usr/src/linux-headers-${version}/tools/objtool ] && {
            run_cmd sudo cp tools/objtool/objtool ${tmp}/usr/src/linux-headers-${version}/tools/objtool
        }

        run_cmd sudo rm -rf ${tmp}/lib/modules/${version}

        run_cmd sudo make -j${MAX_CORES} INSTALL_MOD_PATH=${tmp} modules_install
        run_cmd sudo make -j${MAX_CORES} INSTALL_HDR_PATH=${tmp} headers_install

        run_cmd sudo mkdir -p ${tmp}/usr/lib/modules/${version}

        run_cmd sudo rm -rf ${tmp}/usr/lib/modules/${version}/source
        run_cmd sudo ln -s /usr/src/linux-headers-${version} ${tmp}/usr/lib/modules/${version}/source
        run_cmd sudo rm -rf ${tmp}/usr/lib/modules/${version}/build
        run_cmd sudo ln -s /usr/src/linux-headers-${version} ${tmp}/usr/lib/modules/${version}/build

        run_cmd sudo cp Module.symvers ${tmp}/usr/src/linux-headers-${version}/Module.symvers
        run_cmd sudo cp Makefile ${tmp}/usr/src/linux-headers-${version}/Makefile

        popd > /dev/null

        run_umount ${tmp}
    fi
}

build_initrd()
{
    local vm_level=$1

    check_argument "-l" "vm_level" ${vm_level}

    if [ ${vm_level} = "l0" ]
    then
        echo "Error: build_initrd not supported for ${vm_level}"
        exit 1
    fi

    [ -f linux-${vm_level}/arch/x86/boot/bzImage ] || {
        echo "Error: linux-${vm_level} not built"
        exit 1
    }

    version=$(cat linux-${vm_level}/include/config/kernel.release)

    tmp=$(realpath tmp)
    run_mount ${tmp} ${vm_level}

    [ -d ${tmp}/lib/modules/${version} ] || {
        echo "Error: linux-${vm_level} not installed in ${vm_level}.img"
        exit 1
    }

    run_cmd sudo cp linux-${vm_level}/.config ${tmp}/boot/config-${version}

    run_chroot ${tmp} """
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
apt update

export DEBIAN_FRONTEND=noninteractive
apt install -y initramfs-tools

set +ex
PATH=/usr/sbin/:\$PATH update-initramfs -k ${version} -c -b /boot/
"""
    
    run_cmd sudo cp ${tmp}/boot/initrd.img-${version} linux-${vm_level}/initrd.img-${vm_level}

    run_umount ${tmp}
}

extract_kvm()
{
    local vm_level=$1

    check_argument "-l" "vm_level" ${vm_level}

    kvm=kvm-${vm_level}

    [ -d $kvm ] || {
        mkdir -p $kvm
    }
    rm -rf $kvm/*

    echo "yes"

    for f in $(ls linux-${vm_level}/arch/x86/kvm/*.c)
    do
        run_cmd ln -s $PWD/$f $kvm/$(basename $f)
    done

    for f in $(ls linux-${vm_level}/arch/x86/kvm/*.h)
    do
        run_cmd ln -s $PWD/$f $kvm/$(basename $f)
    done

    for d in $(ls -d linux-${vm_level}/arch/x86/kvm/*/)
    do
        run_cmd ln -s $PWD/$d $kvm/$(basename $d)
    done

    run_cmd ln -s $PWD/linux-${vm_level}/virt $kvm/virt

    targets=""
    for f in $(ls linux-${vm_level}/virt/kvm/*.c)
    do
        target=${f%.?}.o
        targets+="virt\/kvm\/$(basename $target) "
    done

    run_cmd ln -s $PWD/linux-${vm_level}/arch/x86/kvm/Kconfig $kvm/Kconfig

    run_cmd cp linux-${vm_level}/arch/x86/kvm/Makefile $kvm/Makefile

    sed -i '/ccflags-y/s/$/ -IPWD/' $kvm/Makefile
    sed -i "s|-IPWD|-I"$PWD/$kvm"|g" $kvm/Makefile
    sed -i '/include $(srctree)\/virt\/kvm\/Makefile.kvm/a KVM := virt/kvm' $kvm/Makefile
    sed -i '/include $(srctree)\/virt\/kvm\/Makefile.kvm/s/^/#/' $kvm/Makefile

    sed -i "0,/^kvm-y\s\+[-+]\?=\s\+/s//kvm-y                   += ${targets}\\\''\n                          /" $kvm/Makefile
    sed -i "s/''//g" $kvm/Makefile

    echo "make -j -C $PWD/linux-${vm_level} M=$PWD/$kvm" > $kvm/build.sh
    chmod +x $kvm/build.sh
}

# Function to show usage information
usage() {
  echo "Usage: $0 [-t <target>] [-l <vm_level>] [-d <distribution>] [-s <image_size>]" 1>&2
  echo "Options:" 1>&2
  echo "  -t <target>                  Specify which target to run" 1>&2
  echo "                               - options: qemu, image, seabios, ovmf, tdx-module," 1>&2 
  echo "                                 seam-loader, linux, kernel, initrd, kvm, vm" 1>&2
  echo "  -l <vm_level>                Specify the VM nested level" >&2
  echo "                               - options: l0, l1" 1>&2
  echo "  -d <distribution>    Specify the distribution version of Debian" 1>&2
  echo "                               - options: bookworm" 1>&2
  echo "  -s <image_size>              Specify the image size (MB)" 1>&2
  echo "                               - examples: 32768 (32G)" 1>&2
  exit 1
}

# Parse command line options
while getopts ":ht:l:d:s:" opt; do
  case $opt in
    h)
      usage
      ;;
    t)
      target=$OPTARG
      echo "Target: ${target}"
      ;;
    l)
      vm_level=$OPTARG
      echo "VM Level: ${vm_level}"
      ;;
    d)
      distribution=$OPTARG
      echo "Distribution version: ${distribution}"
      ;;
    s)
      image_size=$OPTARG
      echo "Image size: ${image_size}"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

shift $((OPTIND -1))

case $target in
    "phybits")
        fix_phy_bits
        ;;
    "qemu")
        build_qemu ${vm_level} ${distribution}
        ;;
    "image")
        build_image ${vm_level} ${distribution} ${image_size}
        ;;
    "seabios")
        build_seabios
        ;;
    "ovmf")
        build_ovmf
        ;;
    "tdx-module")
        build_tdx_module
        ;;
    "seam-loader")
        build_seam_loader
        ;;
    "linux")
        build_linux ${vm_level}
        ;;
    "kernel")
        install_kernel ${vm_level}
        ;;
    "initrd")
        build_initrd ${vm_level}
        ;;
    "kvm")
        extract_kvm ${vm_level}
        ;;
    "vm")
        finalize_vms
        ;;
    *)
        echo "Please provide -t <target>"
        ;;
esac

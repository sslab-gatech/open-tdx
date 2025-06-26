#!/bin/bash -e

distribution=bookworm
l1_size=16384
l2_size=8192

echo "Running this script will install host kernel"
read -r -p "Is it okay? [y/N] " okay
case ${okay} in
    [yY][eE][sS]|[yY])
        ;;
    *)
        echo "Aborted"
        exit 1
        ;;
esac

echo "Setting up OpenTDX..."

git submodule update --init

./common.sh -t phybits

./common.sh -t qemu -l l0 -d ${distribution}
./common.sh -t image -l l1 -d ${distribution} -s ${l1_size}
./common.sh -t image -l l2 -d ${distribution} -s ${l2_size}
./common.sh -t qemu -l l1 -d ${distribution}

./common.sh -t seabios
./common.sh -t ovmf
./common.sh -t tdx-module
./common.sh -t seam-loader
./common.sh -t linux -l l0
./common.sh -t linux -l l1
./common.sh -t linux -l l2

./common.sh -t kernel -l l0
./common.sh -t kernel -l l1
./common.sh -t kernel -l l2

./common.sh -t initrd -l l1
./common.sh -t initrd -l l2

./common.sh -t kvm -l l0
./common.sh -t kvm -l l1

pushd kvm-l1 >/dev/null
./build.sh
popd >/dev/null

./common.sh -t vm

echo "============================================================"
echo "= Installation is done                                     ="
echo "= Please reboot and select installed kernel in GRUB window ="
echo "============================================================"

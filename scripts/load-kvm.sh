#!/bin/bash -ex

lsmod | grep kvm >/dev/null && {
    modprobe -r kvm_intel
    modprobe -r kvm
}

insmod kvm-l1/kvm.ko
insmod kvm-l1/kvm-intel.ko tdx=1

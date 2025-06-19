#!/bin/bash

suite=jessie
img_file=${suite}.ext4.img

qemu-system-x86_64 \
  -append 'console=ttyS0 root=/dev/sda rw' \
  -drive "file=${img_file},format=raw,cache=writeback" \
  -enable-kvm \
  -nographic \
  -serial mon:stdio \
  -m 2G \
  -smp 2 \
  -net nic,model=e1000 \
  -net user,host=10.0.2.10,hostfwd=tcp:127.0.0.1:10021-:22 \
  -kernel ./vmlinuz \
  -initrd ./initrd.img \
  -cpu host,+smep,+smap \
  -s \
;

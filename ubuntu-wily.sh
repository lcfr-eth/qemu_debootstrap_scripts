#!/usr/bin/env bash
#
# sudo debootstrap wily ./ubuntu-build https://old-releases.ubuntu.com/ubuntu
#
# xenial base install + wily kernel.
#

set -eux
suite=xenial
debootstrap_dir=$suite
img_file=${suite}.ext4.img
kernel=./vmlinuz
initrd=./initrd.img

if [ ! -d "$debootstrap_dir" ]; then
  # Create debootstrap directory.
  sudo debootstrap \
    "$suite" \
    "$debootstrap_dir" \
    http://archive.ubuntu.com/ubuntu \
  ;

  # Set root password.
  echo 'root:root' | sudo chroot "$debootstrap_dir" chpasswd

  # Mount necessary filesystems for chroot operations
  sudo mount -t proc proc "$debootstrap_dir/proc"
  sudo mount -t sysfs sysfs "$debootstrap_dir/sys"
  sudo mount -t devtmpfs devtmpfs "$debootstrap_dir/dev"
  sudo mount -t devpts devpts "$debootstrap_dir/dev/pts"

  # Install the specific kernel
  sudo chroot "$debootstrap_dir" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    apt-get update
    apt-get install -y openssh-server gcc libkeyutils-dev

  cat << EOF | sudo tee /etc/apt/sources.list
deb http://old-releases.ubuntu.com/ubuntu/ wily main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ wily-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ wily-security main restricted universe multiverse
EOF
    apt-get update
    apt-get install -y linux-image-4.2.0-16-generic
  "

  # Copy kernel and initrd to current directory for QEMU
  sudo cp "$debootstrap_dir"/boot/vmlinuz-4.2.0-16-generic ./vmlinuz
  sudo cp "$debootstrap_dir"/boot/initrd.img-4.2.0-16-generic ./initrd.img

  # Unmount filesystems
  sudo umount "$debootstrap_dir/dev/pts"
  sudo umount "$debootstrap_dir/dev"
  sudo umount "$debootstrap_dir/sys"
  sudo umount "$debootstrap_dir/proc"

  # Remount root filesystem as rw.
  cat << EOF | sudo tee "$debootstrap_dir/etc/fstab"
/dev/sda / ext4 errors=remount-ro,acl 0 1
EOF

  # Automaticaly start networking.
  # Otherwise network commands fail with:
  #     Temporary failure in name resolution
  # https://gist.github.com/corvax19/6230283#gistcomment-1940694
  cat << EOF | sudo tee "$debootstrap_dir/etc/systemd/system/dhclient.service"
[Unit]
Description=DHCP Client
Documentation=man:dhclient(8)
Wants=network.target
Before=network.target
[Service]
Type=forking
PIDFile=/var/run/dhclient.pid
ExecStart=/sbin/dhclient -4 -q
[Install]
WantedBy=multi-user.target
EOF

  sudo ln -sf /etc/systemd/system/dhclient.service \
    "${debootstrap_dir}/etc/systemd/system/multi-user.target.wants/dhclient.service"
fi

if [ ! -f "$img_file" ]; then
  # Create disk image
  dd if=/dev/null of="$img_file" bs=1M seek=5048
  mkfs.ext4 "$img_file"
  mnt_dir="${suite}_mnt"
  mkdir "$mnt_dir"
  sudo mount -t ext4 "$img_file" "$mnt_dir"
  sudo cp -r "$debootstrap_dir/." "$mnt_dir"
  sudo umount "$mnt_dir"
  # rmdir "$mnt_dir"
fi

sudo qemu-system-x86_64 \
  -append 'console=ttyS0 root=/dev/sda rw' \
  -drive "file=${img_file},format=raw,cache=writeback" \
  -enable-kvm \
  -nographic \
  -serial mon:stdio \
  -m 2G \
  -kernel "$kernel" \
  -initrd "$initrd" \
;

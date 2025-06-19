#!/bin/bash

set -eux

# Configuration variables
suite=jessie
debootstrap_dir=$suite
img_file=${suite}.ext4.img
kernel=./vmlinuz
initrd=./initrd.img
mirror="http://archive.debian.org/debian"

# Check if debootstrap is installed
if ! command -v debootstrap &> /dev/null; then
    echo "Installing debootstrap..."
    apt-get update
    apt-get install -y debootstrap
fi

if [ ! -d "$debootstrap_dir" ]; then
    # Create debootstrap directory
    sudo debootstrap \
        --arch=amd64 \
        --variant=minbase \
        "$suite" \
        "$debootstrap_dir" \
        "$mirror" \
    ;

    # Set root password
    echo 'root:root' | sudo chroot "$debootstrap_dir" chpasswd

    # Configure sources.list for Jessie (archived)
    cat << EOF | sudo tee "$debootstrap_dir/etc/apt/sources.list"
deb http://archive.debian.org/debian jessie main
deb-src http://archive.debian.org/debian jessie main
EOF

    # Set hostname
    echo "debian-jessie" | sudo tee "$debootstrap_dir/etc/hostname"

    # Configure hosts file
    cat << EOF | sudo tee "$debootstrap_dir/etc/hosts"
127.0.0.1   localhost
127.0.1.1   debian-jessie

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Mount necessary filesystems for chroot operations
    sudo mount -t proc proc "$debootstrap_dir/proc"
    sudo mount -t sysfs sysfs "$debootstrap_dir/sys"
    sudo mount -t devtmpfs devtmpfs "$debootstrap_dir/dev" || sudo mount --bind /dev "$debootstrap_dir/dev"
    sudo mount -t devpts devpts "$debootstrap_dir/dev/pts" || sudo mount --bind /dev/pts "$debootstrap_dir/dev/pts"

    # Install kernel and essential packages
    sudo chroot "$debootstrap_dir" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export LC_ALL=C
        apt-get update
        apt-get install --force-yes -y \
            ca-certificates \
            locales \
            gcc \
            linux-image-3.16.0-6-amd64 \
            openssh-server
    "

    # Find and copy kernel and initrd files
    kernel_version=$(sudo chroot "$debootstrap_dir" ls /boot/ | grep vmlinuz | head -1 | sed 's/vmlinuz-//')
    if [ -n "$kernel_version" ]; then
        sudo cp "$debootstrap_dir/boot/vmlinuz-$kernel_version" ./vmlinuz
        sudo cp "$debootstrap_dir/boot/initrd.img-$kernel_version" ./initrd.img
        echo "Kernel version: $kernel_version"
    else
        echo "Warning: Could not find kernel files"
    fi

    # Configure timezone
    echo "UTC" | sudo tee "$debootstrap_dir/etc/timezone"
    sudo chroot "$debootstrap_dir" dpkg-reconfigure -f noninteractive tzdata

    # Configure locales (after locales package is installed)
    echo "en_US.UTF-8 UTF-8" | sudo tee "$debootstrap_dir/etc/locale.gen"
    sudo chroot "$debootstrap_dir" locale-gen
    echo "LANG=en_US.UTF-8" | sudo tee "$debootstrap_dir/etc/default/locale"

    # Unmount filesystems
    sudo umount "$debootstrap_dir/dev/pts" || true
    sudo umount "$debootstrap_dir/dev" || true
    sudo umount "$debootstrap_dir/sys" || true
    sudo umount "$debootstrap_dir/proc" || true

    # Configure fstab - mount root filesystem as rw
    cat << EOF | sudo tee "$debootstrap_dir/etc/fstab"
/dev/sda / ext4 errors=remount-ro,acl 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devpts /dev/pts devpts gid=5,mode=620 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF

    # Configure network interfaces
    cat << EOF | sudo tee "$debootstrap_dir/etc/network/interfaces"
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet dhcp
EOF

    # Automatically start networking with systemd
    cat << EOF | sudo tee "$debootstrap_dir/etc/systemd/system/dhclient.service"
[Unit]
Description=DHCP Client
Documentation=man:dhclient(8)
Wants=network.target
Before=network.target

[Service]
Type=forking
PIDFile=/var/run/dhclient.pid
ExecStart=/sbin/dhclient -4 -q -pf /var/run/dhclient.pid eth0
ExecStop=/sbin/dhclient -r -pf /var/run/dhclient.pid

[Install]
WantedBy=multi-user.target
EOF

    sudo ln -sf /etc/systemd/system/dhclient.service \
        "${debootstrap_dir}/etc/systemd/system/multi-user.target.wants/dhclient.service"

    # Enable SSH service
    # sudo chroot "$debootstrap_dir" systemctl enable ssh

    # Generate SSH host keys
    #sudo chroot "$debootstrap_dir" ssh-keygen -A

    # Clean up package cache
    #sudo chroot "$debootstrap_dir" apt-get clean

    echo "Debootstrap installation completed: $debootstrap_dir"
fi

if [ ! -f "$img_file" ]; then
    echo "Creating disk image: $img_file"

    # Create disk image (2GB)
    dd if=/dev/null of="$img_file" bs=1M seek=2048

    # Format as ext4
    mkfs.ext4 "$img_file"

    # Mount and copy debootstrap content
    mnt_dir="${suite}_mnt"
    mkdir -p "$mnt_dir"
    sudo mount -t ext4 "$img_file" "$mnt_dir"

    # Copy all content from debootstrap directory to mounted image
    sudo cp -r "$debootstrap_dir/." "$mnt_dir"

    sudo cp -r "$mnt_dir/boot/vmlinuz-3.16.0-6-amd64" ./vmlinuz
    sudo cp -r "$mnt_dir/boot/initrd.img-3.16.0-6-amd64" ./

    # Sync and unmount
    sync
    sudo umount "$mnt_dir"

    echo "Disk image created: $img_file"
fi

echo "Installation complete!"
echo "Files created:"
echo "  - Debootstrap directory: $debootstrap_dir"
echo "  - Disk image: $img_file"
echo "  - Kernel: $kernel"
echo "  - Initrd: $initrd"
echo ""
echo "To boot with QEMU:"
echo "qemu-system-x86_64 -hda $img_file -kernel $kernel -initrd $initrd -append 'root=/dev/sda ro console=ttyS0' -nographic"
echo ""
echo "Note: Debian Jessie is end-of-life and no longer receives security updates."

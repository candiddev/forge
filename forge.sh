#!/usr/bin/env bash
set -eo pipefail

APTCACHER=""
ARCH="amd64"
BINFMT="x86_64"
BOOTOPTIONS=""
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
EXCLUDE="ifupdown"
IMAGEFORMAT="qcow2"
IMAGESIZE="10G"
INSTALLDEPS=""
KEEP=""
LABEL=""
LUKS=""
MOUNT=""
OUTPUTPATH="./debian"
PACKAGES=""
PARTITION=""
ROOTPASSWORD=""
ROOTKEY=""
SSHCA=""
SSHPORT=""
SQUASH=""
SWAPSIZE="2G"
TARGET="container"
TEMPDIR="$(pwd)/tmp"
UNMOUNT=""
VERSION="bullseye"

diskpath=""

function show_usage() {
  echo "Usage: $0 [arguments] [target]

Arguments:
  -ac [apt-cacher-address]  apt-cacher-ng proxy
  -ap [packages]            additional packages to include (default: none)
  -ar [architecture]        architecture (amd64, arm64) (default: ${ARCH})
  -bo                       boot options (default: root=)
  -d                        enable debugging
  -e                        exclude packages (default: ${EXCLUDE})
  -h                        show help
  -if                       image format (qcow2, raw) (default: ${IMAGEFORMAT})
  -is [size]                image size (default: ${IMAGESIZE})
  -k                        keep the disk/image mounted after creation for post-processing
  -la [label]               append a custom label to partition names (default: none)
  -lu [password]            enable LUKS for image
  -m                        mount the disk/image
  -o [path]                 output directory (filesystem/squashfs), target disk (disk) or filename without extension (image) (default: ${OUTPUTPATH})
  -pp                       if hardware device requires a partition prefix, like nvme0n1 partition 1 = nvme0n1p1
  -rk [password]            filename for root SSH public key (default: none)
  -rp [password]            root password (default: none)
  -sc [content]             SSH CA content (default: none)
  -sp [port]                SSH port (default: 22)
  -sw [size]                swap size (default: ${SWAPSIZE})
  -t [path]                 temporary directory used for mounting/prep (default: ${TEMPDIR})
  -u                        unmount the disk/image
  -v [version]              debian version to install (default: ${VERSION})

Targets:
  container                 (default) Deploy Debian as a container within a folder
  disk                      Deploy Debian on a physical disk with an opinionated partitioning scheme
  image                     Deploy Debian on a virtual image for virtualization
  squash                    Deploy Debian as an image that can be used via a USB stick or PXE boot
"
}

function provision() {
  # Create qemu image
  if [ ${TARGET} == image ]; then
    if [ ! -e "${OUTPUTPATH}" ]; then
      mkdir -p "$(dirname ${OUTPUTPATH})"
      qemu-img create -f "${IMAGEFORMAT}" "${OUTPUTPATH}" "${IMAGESIZE}"
      modprobe nbd max_part=4
      qemu-nbd -c /dev/nbd0 -f "${IMAGEFORMAT}" "${OUTPUTPATH}"

      sleep 1
    else
      return 0
    fi
  fi

  # Create partitions
  if [ "${diskpath}" ]; then
    if [ ! -e "/dev/disk/by-label/boot${LABEL}" ]; then
      parted -s "${diskpath}" mklabel gpt
      parted -s "${diskpath}" mkpart primary 1MiB 2MiB
      parted -s "${diskpath}" set 1 bios_grub on
      parted -s "${diskpath}" mkpart primary 2Mib 202MiB
      sleep 1
      mkfs.fat -F 32 -n "boot${LABEL}" "${diskpath}${PARTITION}2"
      parted -s "${diskpath}" mkpart primary 202MiB 100%
      sleep 1
    fi

    # Setup LUKS if specified
    if [ "${LUKS}" ]; then
      if [ ! -e "/dev/disk/by-label/luks${LABEL}" ]; then
        echo "${LUKS}" | cryptsetup --label "luks${LABEL}" -v luksFormat --type luks2 "${diskpath}${PARTITION}3"

        sleep 1
      fi

      if [ ! -e "/dev/mapper/luks${LABEL}" ]; then
        echo "${LUKS}" | cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
        sleep 1
      fi
    fi

    # Setup LVM
    if ! vgdisplay "lvm${LABEL}"; then
      if [ "${LUKS}" ]; then
        vgcreate "lvm${LABEL}" "/dev/mapper/luks${LABEL}"
      else
        vgcreate "lvm${LABEL}" "${diskpath}${PARTITION}3"
      fi
    fi

    sleep 1

    # Create swap
    if [ "${SWAPSIZE}" ] && ! lvdisplay "/dev/lvm${LABEL}/swap${LABEL}"; then
      lvcreate -L "${SWAPSIZE}" -n "swap${LABEL}" "lvm${LABEL}"
      mkswap -L "swap${LABEL}" "/dev/lvm${LABEL}/swap${LABEL}"
    fi

    # Create root
    if ! lvdisplay "/dev/lvm${LABEL}/root${LABEL}"; then
      lvcreate -l 100%FREE -n "root${LABEL}" "lvm${LABEL}"
      mkfs.ext4 -L "root${LABEL}" "/dev/lvm${LABEL}/root${LABEL}"
    fi

    sleep 1
  fi
}

function mountfs() {
  mkdir -p "${TEMPDIR}"

  # Mount disks if necessary
  if [ "${diskpath}" ]; then
    if ! mount | grep "${TEMPDIR}"; then
      if [ "${TARGET}" == image ] && [ ! -e "/dev/disk/by-label/${BOOTPARTITION}${LABEL}" ]; then
        modprobe nbd max_part=4
        qemu-nbd -c /dev/nbd0 -f "${IMAGEFORMAT}" "${OUTPUTPATH}"
        sleep 1
      fi

      if [ "${LUKS}" ] && [ ! -e "/dev/mapper/luks${LABEL}" ]; then
        echo "${LUKS}" | cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
        sleep 1
      fi

      mount "/dev/disk/by-label/root${LABEL}" "${TEMPDIR}"

      if [ "${diskpath}" ]; then
        mkdir -p "${TEMPDIR}/boot"
        mount "/dev/disk/by-label/${BOOTPARTITION}${LABEL}" "${TEMPDIR}/boot"
      fi
    fi

    mkdir -p "${TEMPDIR}/dev"
    mount -o bind /dev "${TEMPDIR}/dev"
    mkdir -p "${TEMPDIR}/proc"
    mount -t proc /proc "${TEMPDIR}/proc"
    mkdir -p "${TEMPDIR}/sys"
    mount -t sysfs /sys "${TEMPDIR}/sys"
  fi
}

function install() {
  PACKAGES="ca-certificates,console-setup,curl,dbus,jq,locales,policykit-1,ssh,${PACKAGES}"
  kernelarch=${ARCH}

  if [ "${diskpath}" ]; then
    BOOTOPTIONS="root=LABEL=root${LABEL} ${BOOTOPTIONS}"
    PACKAGES="console-setup,dosfstools,grub2-common,grub-pc,linux-image-${kernelarch},lvm2,${PACKAGES}"

    if [ "${SWAPSIZE}" ]; then
      BOOTOPTIONS="resume=LABEL=swap${LABEL} ${BOOTOPTIONS}"
    fi
  fi

  if [ "${LUKS}" ]; then
    PACKAGES="cryptsetup,cryptsetup-initramfs,keyutils,${PACKAGES}"
  fi

  if [ "${SQUASH}" ]; then
    PACKAGES="cryptsetup,debootstrap,dosfstools,firmware-atheros,firmware-linux,firmware-iwlwifi,iwd,linux-image-${kernelarch},live-boot,lvm2,parted,${PACKAGES}"
  fi

  if [ ! -e "${TEMPDIR}/bin" ]; then
    deboptions=""
    if ! uname -a | grep "${BINFMT}"; then
      deboptions="--foreign"
    fi

    debootstrap ${deboptions} --arch "${ARCH}" --components=main,contrib,non-free --include="${PACKAGES}" --exclude="${EXCLUDE}" "${VERSION}" "${TEMPDIR}" "http://${APTCACHER}deb.debian.org/debian"

    if ! uname -a | grep "${BINFMT}"; then
      cp "/usr/bin/qemu-${BINFMT}-static" "${TEMPDIR}/usr/bin"
      chroot "${TEMPDIR}" /debootstrap/debootstrap --second-stage
    fi
  fi
}

function configure() {
  # Edit sources
  cat > "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${VERSION} main contrib non-free
deb http://deb.debian.org/debian ${VERSION}-updates main contrib non-free
deb http://security.debian.org/debian-security ${VERSION}-security main contrib non-free
EOF

  # Setup locales
  echo "en_US.UTF-8 UTF-8" > "${TEMPDIR}/etc/locale.gen"
  chroot "${TEMPDIR}" /usr/sbin/locale-gen

  # Dynamic hostname
  rm -f "${TEMPDIR}/etc/hostname" || true

  # Prevent packages from starting services
  cat > "${TEMPDIR}/usr/sbin/policy-rc.d" << EOF
exit 101
EOF

  # Setup networking
  cat >> "${TEMPDIR}/etc/systemd/network/default.network" << EOF
[Match]
Name=ether wlan

[Network]
DHCP=yes
EOF

  # Enable timesyncd
  for service in polkit systemd-networkd systemd-resolved systemd-timesyncd; do
    ln -s "/lib/systemd/system/${service}.service" "${TEMPDIR}/etc/systemd/system/multi-user.target.wants" || true
  done

  # Remove timers
  rm "${TEMPDIR}/etc/systemd/system/timers.target.wants/"* || true

  # Set root SSH key
  if [ "${ROOTKEY}" ]; then
    mkdir -p "${TEMPDIR}/root/.ssh"
    echo "${ROOTKEY}" > "${TEMPDIR}/root/.ssh/authorized_keys"
  fi

  # Set SSH CA
  if [ "${SSHCA}" ]; then
    echo "${SSHCA}" > "${TEMPDIR}/etc/ssh/ca.pem"
    echo "TrustedUserCAKeys /etc/ssh/ca.pem" >> "${TEMPDIR}/etc/ssh/sshd_config"
  fi

  # Set SSH port
  if [ "${SSHPORT}" ]; then
    sed -Ei "s/(#)?Port .*/Port ${SSHPORT}/g" "${TEMPDIR}/etc/ssh/sshd_config"
  fi

  # Set root password
  if [ "${ROOTPASSWORD}" ]; then
    chroot "${TEMPDIR}" bash -c "echo \"root:${ROOTPASSWORD}\" | chpasswd"
  fi
}

function finalize() {
  chroot "${TEMPDIR}" apt clean

  if [ "${diskpath}" ]; then
      sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${BOOTOPTIONS}\"/" ${TEMPDIR}/etc/default/grub
      chroot "${TEMPDIR}" grub-install --target=i386-pc "${diskpath}" || true
      chroot "${TEMPDIR}" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Debian "${diskpath}" || true
      chroot "${TEMPDIR}" grub-mkconfig > "${TEMPDIR}/boot/grub/grub.cfg" || true
      cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=boot${LABEL} /boot vfat defaults 0 0
LABEL=root${LABEL} / ext4 defaults 0 0
EOF

    if [ "${LUKS}" ]; then
      cat >> "${TEMPDIR}/etc/crypttab" << EOF
luks LABEL=luks${LABEL} none luks,initramfs,keyscript=decrypt_keyctl
EOF
    fi

    if [ "${SWAPSIZE}" ]; then
      cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=swap${LABEL} none swap defaults 0 0
EOF
    fi

    chroot "${TEMPDIR}" update-initramfs -u
  fi

  if [ "${SQUASH}" ]; then
    mkdir -p "${TEMPDIR}/etc/systemd/system/getty@tty1.service.d"
    cat > "${TEMPDIR}/etc/systemd/system/getty@tty1.service.d/override.conf" << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 38400 linux
EOF

    # Include additional squash modules
    cat > "${TEMPDIR}/etc/initramfs-tools/modules" << EOF
asix
iwlwifi
usbnet
EOF
    chroot "${TEMPDIR}" update-initramfs -u
    cp -R "${DIR}/forge.sh" "${TEMPDIR}/usr/local/bin/forge.sh"
    mkdir -p "${OUTPUTPATH}/live"
    cp "${TEMPDIR}/vmlinuz" "${OUTPUTPATH}/vmlinuz"
    cp "${TEMPDIR}/initrd.img" "${OUTPUTPATH}/initrd.img"
    mksquashfs "${TEMPDIR}" "${OUTPUTPATH}/live/filesystem.squashfs" -e boot || true
    mkdir -p "${OUTPUTPATH}"/EFI/{BOOT,systemd}
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "${OUTPUTPATH}/EFI/BOOT/BOOTX64.EFI"
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "${OUTPUTPATH}/EFI/systemd/systemd-bootx64.efi"
    mkdir -p "${OUTPUTPATH}/loader/entries"
    cat >> "${OUTPUTPATH}/loader/loader.conf" << EOF
default debian
EOF
    cat >> "${OUTPUTPATH}/loader/entries/debian.conf" << EOF
title Debian
linux /vmlinuz
initrd /initrd.img
options net.ifnames=0 boot=live toram
EOF
  fi
}

function unmountfs() {
  if [ "${diskpath}" ] && [ -z "${KEEP}" ]; then
    umount -R "${TEMPDIR}" || true

    vgchange -a n "lvm${LABEL}" || true

    if [ "${LUKS}" ]; then
      cryptsetup close "/dev/mapper/luks${LABEL}" || true
    fi

    qemu-nbd -d /dev/nbd0 || true
    rmdir "${TEMPDIR}"
  fi
}

if [ -z "${1}" ]; then
  show_usage
  exit 1
fi

while [ $# -gt 0 ]; do
  case "${1}" in
    -ac)
      APTCACHER="${2}/"
      shift 2
    ;;
    -ap)
      PACKAGES="${2}"
      shift 2
    ;;
    -ar)
      case "${2}" in
        amd64)
        ;;
        arm64)
          ARCH=arm64
          BINFMT=aarch64
        ;;
      esac
      shift 2
    ;;
    -bo)
      BOOTOPTIONS="${2}"
      shift 2
    ;;
    -d)
      set -x
      shift 1
    ;;
    -e)
      EXCLUDE="${2}"
      shift 2
    ;;
    -h)
      show_usage
      exit 0
    ;;
    -if)
      case "${2}" in
        qcow2)
          IMAGEFORMAT=qcow2
        ;;
        raw)
          IMAGEFORMAT=raw
        ;;
      esac
      shift 2
    ;;
    -is)
      IMAGESIZE="${2}"
      shift 2
    ;;
    -k)
      KEEP=yes
      shift 1
    ;;
    -la)
      LABEL="-${2}"
      shift 2
    ;;
    -lu)
      LUKS="${2}"
      shift 2
    ;;
    -m)
      MOUNT=yes
      shift 1
    ;;
    -o)
      OUTPUTPATH="${2}"
      shift 2
    ;;
    -pp)
      PARTITION="p"
      shift 1
    ;;
    -rk)
      ROOTKEY="${2}"
      shift 2
    ;;
    -rp)
      ROOTPASSWORD="${2}"
      shift 2
    ;;
    -sc)
      SSHCA="${2}"
      shift 2
    ;;
    -sp)
      SSHPORT="${2}"
      shift 2
    ;;
    -sw)
      SWAPSIZE="${2}"
      shift 2
    ;;
    -t)
      TEMPDIR="${2}"
      shift 2
    ;;
    -u)
      UNMOUNT=yes
      shift 1
    ;;
    -v)
      VERSION="${2}"
      shift 2
    ;;
    filesystem)
      TARGET=container
      TEMPDIR="${OUTPUTPATH}"
      shift 1
    ;;
    disk)
      TARGET=disk
      diskpath="${OUTPUTPATH}"
      shift 1
    ;;
    image)
      TARGET=image
      diskpath="/dev/nbd0"
      PARTITION="p"
      shift 1
    ;;
    squash)
      TARGET=container
      SQUASH=yes
      shift 1
    ;;
    *)
      echo "Unknown option: ${1}"
      show_usage
      exit 1
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

if ! [ -x "$(command -v cryptsetup)" ]; then
  INSTALLDEPS+=" cryptsetup-bin"
fi

if ! [ -x "$(command -v debootstrap)" ]; then
  INSTALLDEPS+=" debootstrap"
fi

if ! [ -x "$(command -v lvm)" ]; then
  INSTALLDEPS+=" lvm2"
fi

if [ "${EFI}" ] && ! [ -x "$(command -v parted)" ]; then
  INSTALLDEPS+=" parted"
fi

if [ "${diskpath}" == /dev/nbd0 ] && ! [ -x "$(command -v qemu-nbd)" ]; then
  INSTALLDEPS+=" qemu-utils"
fi

if [ "${SQUASH}" ] && ! [ -x "$(command -v mksquashfs)" ]; then
  INSTALLDEPS+=" squashfs-tools"
fi

if ! uname -a | grep "${ARCH}" && ! uname -a | grep "${BINFMT}" && ! [ -x "$(command -v /usr/bin/qemu-${BINFMT}-static)" ] ; then
  INSTALLDEPS+=" binfmt-support qemu-user-static"
fi

if [ "${INSTALLDEPS}" ]; then
  apt update && apt install -y ${INSTALLDEPS}
fi

if [ "${MOUNT}" ]; then
  mountfs
  exit
fi

if [ "${UNMOUNT}" ]; then
  unmountfs
  exit
fi

provision
mountfs
install
configure
finalize
unmountfs

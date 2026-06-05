#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# constellation isobuild — archiso profile definition (releng-derived).
#
# Produces a bootable wintermute-<date>.iso that carries:
#   - the enumerated wintermute package set (packages.x86_64)
#   - the local wintermute pacman repo wired into airootfs/etc/pacman.conf
#   - an archinstall answer file (airootfs/root/archinstall.json) seeding a node
#
# An ISO is a point-in-time snapshot: it seeds the day-0 install; the constellation
# ansible tree maintains day-2+. Built with `mkarchiso` (see build-iso.sh).

iso_name="wintermute"
iso_label="WINTERMUTE_$(date +%Y%m)"
iso_publisher="constellation <https://github.com/j0yen>"
iso_application="Wintermute constellation node installer"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=(
  'bios.syslinux.mbr'
  'bios.syslinux.eltorito'
  'uefi-ia32.systemd-boot.esp'
  'uefi-x64.systemd-boot.esp'
  'uefi-ia32.systemd-boot.eltorito'
  'uefi-x64.systemd-boot.eltorito'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')

# File permissions / ownership inside the squashfs.
declare -A file_permissions
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/constellation-firstboot"]="0:0:755"
)

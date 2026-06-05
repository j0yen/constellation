# constellation isobuild

An [archiso](https://wiki.archlinux.org/title/Archiso) `releng`-derived profile
that produces the **golden ISO** for day-0 bare-metal provisioning of a
wintermute node.

**One ISO seeds the install; ansible maintains day-2+.** The image is a
point-in-time snapshot of the base; per-host divergence and ongoing convergence
are owned by `../ansible/`.

## What the ISO carries

- The enumerated installer package set (`packages.x86_64`), derived from archiso
  `releng` and trimmed to installer essentials + provisioning tools
  (archinstall, ansible, git, tailscale).
- The **local wintermute pacman repo** wired into `pacman.conf` (both the
  build-host config and the installed system's `airootfs/etc/pacman.conf`), so
  the ISO ships the **prebuilt `linux-wintermute` kernel** — no per-build
  compile.
- An **archinstall answer file** (`airootfs/root/archinstall.json`) that pins
  `linux-wintermute` as the kernel and seeds a minimal base.
- A **first-boot convergence unit** (`constellation-firstboot.service` +
  `/usr/local/bin/constellation-firstboot`) that, on the *installed* node, clones
  this repo and runs `ansible-playbook site.yml` against localhost — converging
  to the full wintermute set — then self-disables.

## Build

```sh
# 0. Build the local repo first (provides linux-wintermute to the ISO)
../localrepo/build-repo.sh

# 1. Validate the profile (no root / no archiso needed — CI-safe)
./build-iso.sh --validate-only

# 2. Build the ISO (needs root + archiso)
sudo pacman -S --needed archiso
sudo ./build-iso.sh
# -> out/wintermute-<YYYY.MM.DD>-x86_64.iso
```

## Boot test in a VM

```sh
qemu-system-x86_64 -m 4096 -enable-kvm \
  -cdrom out/wintermute-*.iso \
  -bios /usr/share/edk2/x64/OVMF.4m.fd
```

You should land in the live installer with `linux-wintermute` available from the
`wintermute-local` repo and `archinstall` ready (`archinstall --config
/root/archinstall.json`).

## Layout

```
isobuild/
  profiledef.sh                 archiso profile definition (iso name, bootmodes, perms)
  pacman.conf                   build-host pacman.conf (incl. [wintermute-local])
  packages.x86_64               live installer package set
  airootfs/
    etc/pacman.conf             installed system's pacman.conf (incl. [wintermute-local])
    root/archinstall.json       archinstall answer file (pins linux-wintermute)
    usr/local/bin/constellation-firstboot       day-0 convergence script
    etc/systemd/system/constellation-firstboot.service
  build-iso.sh                  validate + mkarchiso driver
```

## Notes

- `customize_airootfs.sh` is deprecated in modern archiso; this profile uses the
  `airootfs/` overlay + a first-boot systemd unit instead.
- The `wintermute-local` `Server =` lines default to `file:///srv/constellation/pkgs`.
  Point them at an `http://` mesh URL to build from / install over the network.

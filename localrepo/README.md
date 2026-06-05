# constellation localrepo

Scripts to build and serve the local wintermute pacman repo that distributes the
prebuilt `linux-wintermute` kernel to all constellation nodes.

**One machine builds; all nodes pull.** No per-host kernel compile.

## Quick start

```sh
# 1. Build the repo from the already-compiled kernel packages
./build-repo.sh

# 2. (Optional) rebuild the kernel first, then add to repo
./build-repo.sh --rebuild

# 3. Serve the repo over HTTP for other nodes
./serve-repo.sh
```

## Layout

```
/srv/constellation/pkgs/x86_64/
  wintermute-local.db.tar.gz
  wintermute-local.files.tar.gz
  linux-wintermute-<ver>-x86_64.pkg.tar.zst
  linux-wintermute-headers-<ver>-x86_64.pkg.tar.zst
```

## pacman.conf entry

Ansible manages this automatically via `ansible/roles/base/tasks/main.yml`.
Manual entry:

```ini
[wintermute-local]
SigLevel = Optional TrustAll
Server = file:///srv/constellation/pkgs/$arch
# or over the mesh:
# Server = http://<control-node-ip>:7878/$arch
```

## Systemd service

To serve the repo permanently on the machine that holds the packages:

```sh
sudo cp constellation-localrepo.service /etc/systemd/system/
sudo systemctl enable --now constellation-localrepo.service
```

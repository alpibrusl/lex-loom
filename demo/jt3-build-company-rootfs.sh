#!/usr/bin/env bash
# jt3-build-company-rootfs.sh -- build the guest image a whole loom company can
# run in (lex-loom#415 step 3). Runs ON the KVM host as root.
#
# Firecracker's quickstart rootfs is Ubuntu 18.04 (glibc 2.27); the prebuilt
# lex binary needs glibc 2.39 (found live: "GLIBC_2.29 not found"). So this
# builds a 4 GB ext4 image from Ubuntu 24.04 base and puts in it: python3,
# curl, ca-certificates, iproute2 (the guest inits need `ip`), sqlite3, git;
# the lex toolchain; a snapshot of lex-loom; its warm lex package cache (lex
# then runs with no GitHub egress); lex-os's guest inits + agent; and
# /etc/hosts pinned to the grant's hosts (the guest has no resolver).
#
# Inputs in JT_DIR (default /tmp/jt3), shipped by bin/jt3-run-on-kvm-host.sh:
#   loom.tgz, packages.tgz. Env: LEX_OS_ROOT, LEX_VERSION (default 0.10.17),
#   FRESH_ROOTFS=1 to rebuild.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }
LEX_OS_ROOT="${LEX_OS_ROOT:-/home/${SUDO_USER:-$USER}/Workspace/alpibrusl/lex-os}"
JT_DIR="${JT_DIR:-/tmp/jt3}"
LEX_VERSION="${LEX_VERSION:-0.10.17}"
BASE_URL="${BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz}"
ASSETS="$LEX_OS_ROOT/demo/assets"
OUT="$ASSETS/loom-company-rootfs.ext4"
GUEST_BIN="$LEX_OS_ROOT/target/x86_64-unknown-linux-musl/release/lex-os-guest"
for f in loom.tgz packages.tgz; do [ -f "$JT_DIR/$f" ] || { echo "missing $JT_DIR/$f" >&2; exit 2; }; done
[ -x "$GUEST_BIN" ] || { echo "no $GUEST_BIN -- build the guest (cargo build --release --target x86_64-unknown-linux-musl -p lex-os-guest --features vsock)" >&2; exit 2; }
if [ -f "$OUT" ] && [ "${FRESH_ROOTFS:-0}" != "1" ]; then echo "reusing $OUT (FRESH_ROOTFS=1 to rebuild)"; exit 0; fi

[ -f "$JT_DIR/ubuntu-base.tgz" ] || curl -fsSL -o "$JT_DIR/ubuntu-base.tgz" "$BASE_URL"
LEX_TGZ="$JT_DIR/lex-v$LEX_VERSION.tgz"
[ -f "$LEX_TGZ" ] || curl -fsSL -o "$LEX_TGZ" "https://github.com/alpibrusl/lex-lang/releases/download/v$LEX_VERSION/lex-v$LEX_VERSION-x86_64-unknown-linux-gnu.tar.gz"

rm -f "$OUT"; truncate -s 4G "$OUT"; mkfs.ext4 -q -F "$OUT"
mnt="$(mktemp -d)"; mount -o loop "$OUT" "$mnt"
cleanup() { umount "$mnt/sys" "$mnt/dev" "$mnt/proc" 2>/dev/null || true; umount "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
echo "+ ubuntu 24.04 base"; tar -xzf "$JT_DIR/ubuntu-base.tgz" -C "$mnt" --numeric-owner
cp /etc/resolv.conf "$mnt/etc/resolv.conf"
mount -t proc proc "$mnt/proc"; mount --bind /dev "$mnt/dev"; mount -t sysfs sys "$mnt/sys"
echo "+ apt (python3 curl ca-certificates iproute2 sqlite3 git procps)"
chroot "$mnt" /bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends python3 ca-certificates curl iproute2 sqlite3 git procps >/dev/null && apt-get clean && rm -rf /var/lib/apt/lists/*'
umount "$mnt/sys" "$mnt/dev" "$mnt/proc"
echo "+ lex $LEX_VERSION"; t="$(mktemp -d)"; tar -xzf "$LEX_TGZ" -C "$t"; install -m 0755 "$(find "$t" -type f -name lex | head -1)" "$mnt/usr/local/bin/lex"; rm -rf "$t"
echo "+ lex-loom snapshot + package cache"; mkdir -p "$mnt/opt/loom" "$mnt/root/.lex"; tar -xzf "$JT_DIR/loom.tgz" -C "$mnt/opt/loom"; tar -xzf "$JT_DIR/packages.tgz" -C "$mnt/root/.lex"
echo "+ lex-os guest inits + agent"; install -m 0755 "$LEX_OS_ROOT/demo/init-attack.sh" "$mnt/sbin/init.demo"; install -m 0755 "$LEX_OS_ROOT/demo/init-agent.sh" "$mnt/sbin/init.agent"; install -m 0755 "$GUEST_BIN" "$mnt/usr/bin/lex-os-guest"
{
  echo "127.0.0.1 localhost"
  for h in html.duckduckgo.com search.yahoo.com search.brave.com www.bing.com example.org; do ip=$(getent ahostsv4 "$h" | awk '{print $1; exit}'); [ -n "$ip" ] && echo "$ip $h"; done
} > "$mnt/etc/hosts"
rm -f "$mnt/etc/resolv.conf"   # no resolver in the box: names come from /etc/hosts, pinned like the wall
echo "+ sanity: glibc $(ls "$mnt"/lib/x86_64-linux-gnu/libc.so.6 >/dev/null && chroot "$mnt" /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null | head -1 | cut -c1-60), lex $(chroot "$mnt" /usr/local/bin/lex --version 2>&1 | head -1)"
cleanup; trap - EXIT; rmdir "$mnt"
echo "rootfs ready: $OUT ($(du -h "$OUT" | cut -f1) used of 4G)"

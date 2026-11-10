#!/usr/bin/env bash
# flash_tracked.sh - build, flash and tag, so every image on the unit has a tag.
#
#   scripts/flash_tracked.sh [-t make-target] [-p port] [-m note] [--iap] [--no-push] [--dry-run]
#
# --iap: the unit is in firmware-update mode (MENU + pinhole reset, IAP drive):
#        flash through scripts/iap_flash.py instead of the CDC shell. Asks for sudo
#        (raw IAP write). Remote, no terminal: FLASH_SUDO_STDIN=1 and pipe
#        "<password>\ny\n" into the script.
#
# 1. refuses a dirty tree (the tag must describe exactly what was flashed)
# 2. make <target> (default guest-coldtrace-meter); the image carries the git rev
# 3. RAM-installer check (issue #42) of the new image and of the running one
# 4. archives the .bin in $IMAGES/<tag>.bin, flashes it with cdc_flash.py
# 5. waits for the unit to come back and checks it reports that git rev
# 6. only then: annotated tag flashed/<date>-<time>-<target>, push branch + tag to `fork`
# A failed flash or a unit that reports another rev gets no tag.
set -euo pipefail

TARGET=guest-coldtrace-meter
PORT=/dev/ttyACM1
NOTE=""
PUSH=1
DRY=0
IAP=0
REMOTE=fork
IMAGES=${OPENSCOPE_IMAGES:-$HOME/src/openscope-images/flashed}
PY=${OPENSCOPE_PY:-$HOME/opt/openscope-venv/bin/python}
export PATH=$HOME/opt/arm-gnu-toolchain/bin:$PATH

while [ $# -gt 0 ]; do
  case $1 in
    -t|--target) TARGET=$2; shift 2;;
    -p|--port) PORT=$2; shift 2;;
    -m|--note) NOTE=$2; shift 2;;
    --no-push) PUSH=0; shift;;
    --dry-run) DRY=1; shift;;
    --iap) IAP=1; shift;;
    -h|--help) sed -n 2,18p "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

die() { echo "flash_tracked: $*" >&2; exit 1; }
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$REPO"

case $TARGET in guest*) ;; *) die "target $TARGET is not a guest (0x08007000) build; cdc_flash would install it 0x3000 off";; esac
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes; commit them first so the tag matches the image"
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || die "detached HEAD; check out a branch"
REV=$(git rev-parse --short=10 HEAD)
unit_fw() {   # firmware string the unit reports, empty if it does not answer
  (cd tools/openscope_host && timeout 8 "$PY" -m openscope --port "$PORT" info 2>/dev/null | sed -n "s/^firmware *//p") || true
}
if [ $IAP = 0 ]; then
  if fuser "$PORT" >/dev/null 2>&1; then
    die "$PORT is held by: $(fuser "$PORT" 2>/dev/null | xargs -r ps -o pid=,cmd= -p | head -3)"
  fi
  [ -n "$(unit_fw)" ] || die "unit does not answer on $PORT; put it in firmware-update mode (MENU + pinhole reset) and use --iap"
else
  "$PY" scripts/iap_flash.py status 2>&1 | grep -q "Upgrade mode" || die "--iap: no unit in firmware-update mode (IAP drive) found"
fi

echo "== build $TARGET at $BRANCH $REV"
# serial on purpose: the guest targets are 'clean all', and -j races the rm -rf build
make -C firmware "$TARGET" > /tmp/flash_tracked_build.log 2>&1 \
  || { tail -20 /tmp/flash_tracked_build.log; die "build failed (log: /tmp/flash_tracked_build.log)"; }
BIN=firmware/build/firmware.bin
grep -aq "OpenScope [A-Z][a-z][a-z] .* $REV" "$BIN" || die "built image does not carry rev $REV"

echo "== RAM-installer check"
"$PY" scripts/test_ramfunc_isolated.py --check-bin "$BIN"
if [ $IAP = 1 ]; then
  echo "   (IAP: the factory bootloader installs, running image not involved)"
elif [ -e "$IMAGES/current.bin" ]; then
  "$PY" scripts/test_ramfunc_isolated.py --check-bin "$IMAGES/current.bin" \
    || die "the RUNNING image ($(readlink -f "$IMAGES/current.bin")) has an unsafe installer; use IAP"
else
  echo "   (no $IMAGES/current.bin: running image unknown, not checked)"
fi

STAMP=$(date +%Y%m%d-%H%M)
TAG="flashed/$STAMP-${TARGET#guest-}"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG exists already"
OUT="$IMAGES/${TAG#flashed/}_$REV.bin"
if [ $DRY = 1 ]; then echo "== dry run: would archive $OUT, flash it and tag $TAG"; exit 0; fi
mkdir -p "$IMAGES"
cp "$BIN" "$OUT"
SHA=$(sha256sum "$OUT" | cut -d" " -f1)
echo "   archived $OUT"

echo "== flash"
if [ $IAP = 1 ]; then
  # the bootloader looks for APP_*.bin; the archive keeps its own name
  IAPDIR=$(mktemp -d); IAPBIN="$IAPDIR/APP_2C53T_openscope_$REV.bin"; cp "$OUT" "$IAPBIN"
  # the raw IAP write needs root; run the tool under sudo once. Without a terminal
  # (remote), FLASH_SUDO_STDIN=1 makes sudo read the password from the first stdin
  # line; the next line ("y") answers the tool's Proceed prompt.
  if [ -n "${FLASH_SUDO_STDIN:-}" ]; then
    sudo -S -p "" "$PY" scripts/iap_flash.py flash "$IAPBIN" || die "IAP flash failed; no tag set"
  else
    sudo "$PY" scripts/iap_flash.py flash "$IAPBIN" || die "IAP flash failed; no tag set"
  fi
  rm -rf "$IAPDIR"
else
  # cdc_flash exits non-zero when the port vanishes on reset; the version check below decides
  timeout 180 "$PY" scripts/cdc_flash.py "$OUT" --port "$PORT" 2>&1 | tail -3 || true
fi

echo "== waiting for the unit"
FW=""
for _ in $(seq 1 30); do
  sleep 2
  FW=$(unit_fw)
  [ -n "$FW" ] && break
done
[ -n "$FW" ] || die "unit did not come back within 60 s; no tag set (recovery: hold MENU through a pinhole reset)"
case $FW in *" $REV") ;; *) die "unit reports \"$FW\", expected rev $REV; no tag set";; esac
echo "   unit reports: $FW"

git tag -a "$TAG" -F - <<MSG
Flashed $STAMP: make $TARGET on $BRANCH ($([ $IAP = 1 ] && echo IAP || echo CDC))

rev:      $REV
target:   $TARGET
image:    $(basename "$OUT") ($(stat -c %s "$OUT") B)
sha256:   $SHA
device:   $FW
${NOTE:+note:     $NOTE}
MSG
ln -sfn "$(basename "$OUT")" "$IMAGES/current.bin"
echo "== tagged $TAG"

if [ $PUSH = 1 ]; then
  git -c credential.helper= -c credential.helper="!gh auth git-credential" push -q "$REMOTE" "$BRANCH" "refs/tags/$TAG" \
    && echo "== pushed $BRANCH and $TAG to $REMOTE" \
    || echo "flash_tracked: push failed; tag is local, push later with: git push $REMOTE $BRANCH $TAG" >&2
fi

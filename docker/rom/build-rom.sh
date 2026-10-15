#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
    echo "This image accepts no arguments. Set JOBS to choose parallelism." >&2
    exit 2
fi

if [ ! -f /source/Makefile ] || [ ! -d /source/src ]; then
    echo "ROM sources are missing. Run git submodule update --init --recursive first." >&2
    exit 1
fi

jobs=${JOBS-$(nproc)}
case "$jobs" in
    ''|*[!0-9]*)
        echo "JOBS must be an integer between 1 and 256." >&2
        exit 2
        ;;
esac
while [ "${jobs#0}" != "$jobs" ]; do
    jobs=${jobs#0}
done
if [ -z "$jobs" ] || [ "${#jobs}" -gt 3 ] || [ "$jobs" -gt 256 ]; then
    echo "JOBS must be an integer between 1 and 256." >&2
    exit 2
fi

cd /build/rom
echo "Copying ROM sources into the container's Linux filesystem..."
# Keep required data/mb_*.gba inputs. Only root-level build outputs are excluded.
rsync -a --exclude=/.git --exclude=/build/ \
    --exclude='/pokeemerald*.gba' --exclude='/pokeemerald*.elf' \
    --exclude='/pokeemerald*.map' --exclude='/pokeemerald*.sym' \
    /source/ /build/rom/

# Remove any host-built tools/generated assets from the private copy, never /source.
make --silent clean
echo "Building pokeemerald with $(arm-none-eabi-gcc --version | head -n 1), jobs=$jobs..."
make --silent modern -j"$jobs"

for artifact in pokeemerald_modern.gba pokeemerald_modern.elf pokeemerald_modern.map; do
    if [ ! -s "$artifact" ]; then
        echo "Build did not produce $artifact." >&2
        exit 1
    fi
done

for artifact in pokeemerald_modern.gba pokeemerald_modern.elf pokeemerald_modern.map; do
    cp "$artifact" "/source/$artifact"
    # Keep outputs writable by the checkout owner on Linux as well as Windows.
    if [ "$(id -u)" -eq 0 ]; then
        chown "$(stat -c '%u:%g' /source)" "/source/$artifact"
    fi
done

echo "Build complete. Outputs are in rom/. Compare this ROM SHA1 with another developer:"
sha1sum pokeemerald_modern.gba

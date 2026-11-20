#!/usr/bin/env bash
# Run from the host after checking the stock FFT baseline and disconnecting JTAG.
set -euo pipefail
if (( $# < 2 || $# > 3 )); then
    echo 'Usage: profile-board.sh user@board input.s16le [symmetric|buffered]' >&2
    exit 2
fi
case "${3:-}" in
    '') variants=(serial parallel) ;;
    symmetric) variants=(parallel symmetric wide) ;;
    buffered) variants=(wide buffered) ;;
    *) echo 'Unknown comparison mode' >&2; exit 2 ;;
esac
target=$1
input=$(realpath "$2")
cd "$(dirname "$0")"
mkdir -p build/profiling
output=$(mktemp -d "$PWD/build/profiling/board.XXXXXX")
bundle="$output/payload"
mkdir "$bundle"
echo "Local evidence directory: $output"
test "$(wc -c < "$input")" -eq 32768
cp "$input" "$bundle/input.s16le"
cp fir128_test.c arm_bench.c reference.h coeff.inc ../sw/fpga_irqs_off.c "$bundle/"
for variant in "${variants[@]}"; do
    build="build/fir128-$variant"
    (cd "$build" && sha256sum -c firmware.sha256)
    awk '
        /^Type.* (Setup|Hold) .*FPGA_CLK1_50/ {
            kind = ($0 ~ / Setup / ? "setup" : "hold")
            if (getline != 1 || $1 != "Slack" || $3 !~ /^-?[0-9]+[.][0-9]+$/) {
                invalid = 1
                next
            }
            if (!(kind in minimum) || $3 + 0 < minimum[kind]) minimum[kind] = $3 + 0
        }
        END {
            if (invalid || !("setup" in minimum) || !("hold" in minimum) ||
                minimum["setup"] < 0 || minimum["hold"] < 0) exit 1
            printf "50 MHz setup slack %.3f ns; hold slack %.3f ns\n", minimum["setup"], minimum["hold"]
        }
    ' "$build/output_files/DE10_NANO_SoC_GHRD.sta.summary" | tee "$output/$variant-timing.log"
    cp "$build/fir128.rbf" "$bundle/fir128-$variant.rbf"
    sed "s/fir128\.rbf/fir128-$variant.rbf/" fir128.dts > "$output/$variant.dts"
    dtc -@ -I dts -O dtb -o "$bundle/fir128-$variant.dtbo" "$output/$variant.dts"
done
(cd "$bundle" && sha256sum input.s16le ./*.rbf ./*.dtbo > payload.sha256)

ssh_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5
             -o ServerAliveCountMax=3 -o UpdateHostKeys=no -o StrictHostKeyChecking=yes)
stage=$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/fir128-profile.XXXXXX')
[[ $stage =~ ^/tmp/fir128-profile\.[a-zA-Z0-9]+$ ]]
tar -C "$bundle" -cf - . | ssh "${ssh_options[@]}" "$target" "cd '$stage' && tar -xf -"

status=0
ssh "${ssh_options[@]}" "$target" "cd '$stage' && sh -s -- ${variants[*]}" <<'BOARD' 2>&1 | tee "$output/session.log" || status=$?
set -eu
mkdir evidence
ov=/sys/kernel/config/device-tree/overlays
manager=/sys/class/fpga_manager/fpga0/state
test "$(ls -A "$ov")" = de10-nano.dtbo
test "$(cat "$ov/de10-nano.dtbo/status")" = applied
test "$(cat "$ov/de10-nano.dtbo/path")" = de10-nano.dtbo
test "$(cat "$manager")" = operating
test "$(systemctl is-enabled de10-nano-fpga-init)" = enabled
test "$(od -An -tx1 /proc/device-tree/memory/reg | xargs)" = '00 00 00 00 40 00 00 00'
test "$(awk '{$1=$1; print}' /sys/kernel/debug/memblock/memory)" = '0: 0x00000000..0x2f7fffff'
sha256sum /media/FAT/de10-nano.rbf /lib/firmware/de10-nano.dtbo > evidence/stock.sha256
cat /proc/sys/kernel/random/boot_id > evidence/boot-before
sha256sum -c payload.sha256
gcc -O2 -Wall -Wextra -Werror -std=c11 fir128_test.c -o fir128_test
if [ "$1" != serial ]; then
    gcc -O2 -Wall -Wextra -Werror -std=c11 -pthread -mcpu=cortex-a9 -mfpu=neon arm_bench.c -o arm_bench
fi
gcc -O2 -Wall -Wextra -D_FILE_OFFSET_BITS=64 fpga_irqs_off.c -o fpga_irqs_off
for artifact in ./*.rbf ./*.dtbo; do
    test ! -e "/lib/firmware/${artifact#./}"
done
cat /proc/interrupts > evidence/irq-stock.log
touch evidence/stock-disruption-started
umask 022
cp ./*.rbf ./*.dtbo /lib/firmware/
systemctl stop de10-nano-xfce-init.service de10-nano-fpga-leds.service de10-nano-fftsw-init.service
if [ -d /sys/module/fft_driver ]; then rmmod fft_driver; fi
test ! -d /sys/module/fft_driver
for driver in leds-gpio gpio-keys; do
    case "$driver" in leds-gpio) name=leds ;; gpio-keys) name=keys ;; esac
    base=/sys/bus/platform/drivers/$driver
    device=soc:base-fpga-region:$name
    if [ -L "$base/$device" ]; then printf '%s' "$device" > "$base/unbind"; fi
done
rmdir "$ov/de10-nano.dtbo"
./fpga_irqs_off
if [ "$1" != serial ]; then
    if ! ./arm_bench input.s16le > evidence/arm-bench.log 2>&1; then
        cat evidence/arm-bench.log
        exit 1
    fi
    cat evidence/arm-bench.log
fi

for variant in "$@"; do
    case "$variant" in serial) lanes=1 ;; parallel) lanes=4 ;; symmetric) lanes=8 ;; wide|buffered) lanes=16 ;; esac
    slot="fir128-$variant"
    mkdir "$ov/$slot"
    printf '%s' "$slot.dtbo" > "$ov/$slot/path"
    test "$(cat "$ov/$slot/status")" = applied
    test "$(cat "$manager")" = operating
    test "$(tr -d '\000' < /proc/device-tree/soc/base-fpga-region/firmware-name)" = "$slot.rbf"
    for trial in 1 2 3 4 5; do
        log="evidence/$variant-$trial.log"
        echo "$variant trial $trial"
        if ! ./fir128_test input.s16le "evidence/$variant-$trial-arm.s16le" \
             "evidence/$variant-$trial-fpga.s16le" > "$log" 2>&1; then
            cat "$log"
            exit 1
        fi
        grep -F "($lanes taps per clock)" "$log"
        if [ "$variant" = buffered ]; then
            grep -Fx 'DDR transfers overlap compute' "$log"
        fi
        cat "$log"
    done
    cat /proc/interrupts > "evidence/irq-$variant.log"
    rmdir "$ov/$slot"
    ./fpga_irqs_off
done
(cd evidence && sha256sum ./*.s16le > outputs.sha256)
for artifact in ./*.rbf ./*.dtbo; do
    unlink "/lib/firmware/${artifact#./}"
done
BOARD

evidence_status=0
ssh "${ssh_options[@]}" "$target" "cd '$stage' && tar -cf - evidence" |
    tar -xf - -C "$output" || evidence_status=$?
if [[ -f $output/evidence/stock-disruption-started ]]; then
    echo "Restoring stock FPGA via reboot. Reattach the USB gadget if needed."
    ssh "${ssh_options[@]}" "$target" 'sync && systemctl reboot' || true
fi
if (( status != 0 || evidence_status != 0 )); then
    echo "See $output/session.log for the last completed step." >&2
    exit 1
fi
(
    cd "$output/evidence"
    sha256sum -c outputs.sha256
    for pcm in ./*.s16le; do cmp "./${variants[0]}-1-arm.s16le" "$pcm"; done
)
echo "FPGA profiling evidence saved in $output/evidence"

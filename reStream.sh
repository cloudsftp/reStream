#!/bin/sh

# default values for arguments
ssh_host="root@10.11.99.1" # remarkable connected through USB
landscape=true             # rotate 90 degrees to the right
output_path=-              # display output through ffplay
format=-                   # automatic output format
webcam=false               # not to a webcam
measure_throughput=false   # measure how fast data is being transferred

# loop through arguments and process them
while [ $# -gt 0 ]; do
    case "$1" in
        -p | --portrait)
            landscape=false
            shift
            ;;
        -s | --source)
            ssh_host="$2"
            shift
            shift
            ;;
        -o | --output)
            output_path="$2"
            shift
            shift
            ;;
        -f | --format)
            format="$2"
            shift
            shift
            ;;
        -t | --throughput)
            measure_throughput=true
            shift
            ;;
        -w | --webcam)
            webcam=true
            format="v4l2"

            # check if there is a modprobed v4l2 loopback device
            # use the first cam as default if there is no output_path already
            cam_path=$(v4l2-ctl --list-devices \
                | sed -n '/^[^\s]\+platform:v4l2loopback/{n;s/\s*//g;p;q}')

            # fail if there is no such device
            if [ -e "$cam_path" ]; then
                if [ "$output_path" = "-" ]; then
                    output_path="$cam_path"
                fi
            else
                echo "Could not find a video loopback device, did you"
                echo "sudo modprobe v4l2loopback"
                exit 1
            fi
            shift
            ;;
        -h | --help | *)
            echo "Usage: $0 [-p] [-s <source>] [-o <output>] [-f <format>]"
            echo "Examples:"
            echo "	$0                              # live view in landscape"
            echo "	$0 -p                           # live view in portrait"
            echo "	$0 -s 192.168.0.10              # connect to different IP"
            echo "	$0 -o remarkable.mp4            # record to a file"
            echo "	$0 -o udp://dest:1234 -f mpegts # record to a stream"
            echo "  $0 -w                           # write to a webcam (yuv420p + resize)"
            exit 1
            ;;
    esac
done

# list of ffmpeg filters to apply
video_filters="null"

ssh_cmd() {
    echo "[SSH]" "$@" >&2
    ssh -o ConnectTimeout=1 "$ssh_host" "$@"
}

# check if we are able to reach the remarkable
if ! ssh_cmd true; then
    echo "$ssh_host unreachable"
    exit 1
fi

rm_version="$(ssh_cmd cat /sys/devices/soc0/machine)"

case "$rm_version" in
    "reMarkable 1.0")
        width=1408
        height=1872
        bytes_per_pixel=2
        pixel_format="rgb565le"
        # calculate how much bytes the window is
        window_bytes="$((width * height * bytes_per_pixel))"
        # read the first $window_bytes of the framebuffer
        head_fb0="dd if=/dev/fb0 count=1 bs=$window_bytes 2>/dev/null"
        ;;
    "reMarkable 2.0")
        pixel_format="gray8"
        width=1872
        height=1404
        bytes_per_pixel=1

        # calculate how much bytes the window is
        window_bytes="$((width * height * bytes_per_pixel))"

        # find xochitl's process
        pid="$(ssh_cmd pidof xochitl)"
        echo "xochitl's PID: $pid"

        # find framebuffer location in memory
        # it is actually the map allocated _after_ the fb0 mmap
        read_address="grep -C1 '/dev/fb0' /proc/$pid/maps | tail -n1 | sed 's/-.*$//'"
        skip_bytes_hex="$(ssh_cmd "$read_address")"
        skip_bytes="$((0x$skip_bytes_hex + 8))"
        echo "framebuffer is at 0x$skip_bytes_hex"

        # carve the framebuffer out of the process memory
        page_size=4096
        window_start_blocks="$((skip_bytes / page_size))"
        window_offset="$((skip_bytes % page_size))"
        window_length_blocks="$((window_bytes / page_size + 1))"

        # find custom head
        if ssh_cmd "[ -f /opt/bin/head ]"; then
            head="/opt/bin/head"
        elif ssh_cmd "[ -f ~/head ]"; then
            head="~/head"
        fi

        # Using dd with bs=1 is too slow, so we first carve out the pages our desired
        # bytes are located in, and then we trim the resulting data with what we need.
        head_fb0="dd if=/proc/$pid/mem bs=$page_size skip=$window_start_blocks count=$window_length_blocks 2>/dev/null | tail -c+$window_offset | $head -c $window_bytes"

        # rotate by 90 degrees to the right
        video_filters="$video_filters,transpose=2"
        ;;
    *)
        echo "Unsupported reMarkable version: $rm_version."
        echo "Please visit https://github.com/rien/reStream/ for updates."
        exit 1
        ;;
esac

# technical parameters
loop_wait="true"
loglevel="info"

fallback_to_gzip() {
    echo "Falling back to gzip, your experience may not be optimal."
    echo "Go to https://github.com/rien/reStream/#sub-second-latency for a better experience."
    compress="gzip"
    decompress="gzip -d"
    sleep 2
}

# check if lz4 is present on remarkable
if ssh_cmd "[ -f /opt/bin/lz4 ]"; then
    compress="/opt/bin/lz4"
elif ssh_cmd "[ -f ~/lz4 ]"; then
    compress="\$HOME/lz4"
fi

# gracefully degrade to gzip if is not present on remarkable or host
if [ -z "$compress" ]; then
    echo "Your remarkable does not have lz4."
    fallback_to_gzip
elif ! lz4 -V >/dev/null; then
    echo "Your host does not have lz4."
    fallback_to_gzip
else
    decompress="lz4 -d"
fi

# use pv to measure throughput if desired, else we just pipe through cat
if $measure_throughput; then
    if ! pv --version >/dev/null; then
        echo "You need to install pv to measure data throughput."
        exit 1
    else
        loglevel="error" # verbose ffmpeg output interferes with pv
        host_passthrough="pv"
    fi
else
    host_passthrough="cat"
fi

# store extra ffmpeg arguments in $@
set --

# rotate 90 degrees if landscape=true
$landscape && video_filters="$video_filters,transpose=1"

# Scale and add padding if we are targeting a webcam because a lot of services
# expect a size of exactly 1280x720 (tested in Firefox, MS Teams, and Skype for
# for business). Send a PR is you can get a heigher resolution working.
if $webcam; then
    video_filters="$video_filters,format=pix_fmts=yuv420p"
    if $landscape; then
        render_width=$((720 * height / width))
    else
        render_width=$((720 * width / height))
    fi

    # center
    offset_left=$(((1280 - render_width) / 2))
    video_filters="$video_filters,scale=${render_width}x720"
    video_filters="$video_filters,pad=1280:720:$offset_left:0:#eeeeee"
fi

# set each frame presentation time to the time it is received
video_filters="$video_filters,setpts=(RTCTIME - RTCSTART) / (TB * 1000000)"

# loop that keeps on reading and compressing, to be executed remotely
read_loop="while $head_fb0; do $loop_wait; done | $compress"

set -- "$@" -vf "${video_filters#,}"

if [ "$output_path" = - ]; then
    output_cmd=ffplay
else
    output_cmd=ffmpeg

    if [ "$format" != - ]; then
        set -- "$@" -f "$format"
    fi

    set -- "$@" "$output_path"
fi

set -e # stop if an error occurs

# shellcheck disable=SC2086
ssh_cmd "$read_loop" \
    | $decompress \
    | $host_passthrough \
    | "$output_cmd" \
        -vcodec rawvideo \
        -loglevel "$loglevel" \
        -f rawvideo \
        -pixel_format "$pixel_format" \
        -video_size "$width,$height" \
        -i - \
        "$@"

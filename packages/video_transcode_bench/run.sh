#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -Eeo pipefail
#trap SIGINT SIGTERM ERR EXIT


BREPS_LFILE=/tmp/ffmpeg_log.txt

function benchreps_tell_state () {
    date +"%Y-%m-%d_%T ${1}" >> $BREPS_LFILE
}

if [ "${DCPERF_PERF_RECORD:-unset}" = "unset" ]; then
    export DCPERF_PERF_RECORD=0
fi

# Constants
FFMPEG_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

show_help() {
cat <<EOF
Usage: ${0##*/} [-h] [--encoder svt|aom|x264] [--levels low:high]|[--runtime long|medium|short]|[--parallelism 0-6]|[--procs {number of jobs}]

    -h Display this help and exit
    --encoder encoder name. Default: svt
    --parallelism encoder's level of parallelism. Default: 1
    --procs number of parallel jobs. Default: -1
    --output Result output file name. Default: "ffmpeg_video_workload_results.txt"
    --quick Quick mode: uses only 1 resolution and fastest encoding level (preset 13 for SVT-AV1) (default: 0)
    --max-resolutions N Limit number of resolutions to use (default: all 7, quick mode: 1)
EOF
}


delete_replicas() {
    if [ -d "${FFMPEG_ROOT}/resized_clips" ]; then
        pushd "${FFMPEG_ROOT}/resized_clips"
        rm ./* -rf
        popd
    fi
}

collect_perf_record() {
    sleep 60
    if [ -f "perf.data" ]; then
    benchreps_tell_state "collect_perf_record: already exist"
        return 0
    fi
    benchreps_tell_state "collect_perf_record: collect perf"
    perf record -a -g -- sleep 5 >> /tmp/perf-record.log 2>&1
}

main() {
    local encoder
    encoder="svt"

    local levels
    levels="0:0"

    local result_filename
    result_filename="ffmpeg_video_workload_results.txt"

    local runtime
    runtime="medium"

    local lp
    lp="1"

    local procs
    procs="-1"

    local quick_mode=0
    local max_resolutions=0

    while :; do
        case $1 in
            --levels)
                levels="$2"
                ;;
            --encoder)
                encoder="$2"
                ;;
            --output)
                result_filename="$2"
                ;;
            --runtime)
                runtime="$2"
                ;;
            --parallelism)
                lp="$2"
                ;;
            --procs)
                procs="$2"
                ;;
            --quick)
                quick_mode="$2"
                ;;
            -h)
                show_help >&2
                exit 1
                ;;
            *)  # end of input
                echo "Unsupported arg $1"
                break
        esac

        case $1 in
            --levels|--encoder|--output|--runtime|--parallelism|--procs|--quick)
                if [ -z "$2" ]; then
                    echo "Invalid option: $1 requires an argument" 1>&2
                    exit 1
                fi
                shift   # Additional shift for the argument
                ;;
        esac
        shift
    done



    if [ "$encoder" = "svt" ]; then
        if [ "$levels" = "0:0" ]; then
            if [ "$runtime" = "short" ]; then
                levels="12:13"
            elif [ "$runtime" = "medium" ]; then
                levels="6:6"
            elif [ "$runtime" = "long" ]; then
                levels="2:2"
            else
                echo "Invalid runtime, available options are short, medium, and long"
                exit 1
            fi
        fi
        if [ $lp -gt 6 ]; then
            echo "Invalid level of parallelism, available options range is [-1, 6]"
            exit 1
        fi
    elif [ "$encoder" = "aom" ]; then
        if [ "$levels" = "0:0" ]; then
            if [ "$runtime" = "short" ]; then
                levels="6:6"
            elif [ "$runtime" = "medium" ]; then
                levels="5:5"
            elif [ "$runtime" = "long" ]; then
                levels="3:3"
            else
                echo "Invalid runtime, available options are short, medium, and long"
                exit 1
            fi
        fi
    elif [ "$encoder" = "x264" ]; then
        if [ "$levels" = "0:0" ]; then
            if [ "$runtime" = "short" ]; then
                levels="3:3"
            elif [ "$runtime" = "medium" ]; then
                levels="6:6"
            else
                echo "Invalid runtime, available options are short, medium, and long"
                exit 1
            fi
        fi
    else
            echo "Invalid encoder, available options are svt and aom"
            exit 1
    fi

    # Quick mode: use fastest encoding level and limit resolutions
    if [ $quick_mode -eq 1 ]; then
        echo "[PROGRESS] Quick mode enabled: using fastest encoding level and minimal resolutions"
        if [ "$encoder" = "svt" ]; then
            levels="13:13"  # Fastest preset for SVT-AV1
        elif [ "$encoder" = "aom" ]; then
            levels="6:6"    # Fast preset for AOM
        elif [ "$encoder" = "x264" ]; then
            levels="3:3"   # Fast preset for x264
        fi
        
        limited_resolutions="[(256,144)]"
        sed -i "s|^downscale_target_resolutions.*=.*|downscale_target_resolutions             = $limited_resolutions #8bit elfuente|" ./generate_commands_all.py
        
        # Set QP_VALUES to only [23] in quick mode (for svt/aom encoders)
        if [ "$encoder" = "svt" ] || [ "$encoder" = "aom" ]; then
            sed -i "s|^    QP_VALUES.*=.*\[23,27,31,35,39,43,47,51,55,59,63\].*#elfuente_qps|    QP_VALUES               = [23] #elfuente_qps|" ./generate_commands_all.py
        elif [ "$encoder" = "x264" ]; then
            sed -i "s|^    QP_VALUES.*=.*\[19,21,23,25,27,29,31,33,35,37,41\].*#elfuente_qps|    QP_VALUES               = [19] #elfuente_qps|" ./generate_commands_all.py
        fi
    fi

    set -u  # Enable unbound variables check from here onwards
    echo "[PROGRESS] Starting video transcode benchmark..."
    echo "[PROGRESS] Encoder: $encoder, Levels: $levels, Runtime: $runtime"
    benchreps_tell_state "working on config"
    pushd "${FFMPEG_ROOT}"

    echo "[PROGRESS] Cleaning up previous run artifacts..."
    delete_replicas

    #Customize the script to genrate commands
    echo "[PROGRESS] Configuring encoding parameters..."
    sed -i "/^ENC/d" ./generate_commands_all.py
    sed -i "/^num_pool/d" ./generate_commands_all.py
    sed -i "/^lp_number/d" ./generate_commands_all.py
    if [ "$encoder" = "svt" ]; then
        sed -i '/^bitstream\_folders/a ENCODER\=\"ffmpeg-svt\"' ./generate_commands_all.py
        run_sh="ffmpeg-svt-1p-run-all-paral.sh"
    elif [ "$encoder" = "x264" ]; then
        sed -i '/^bitstream\_folders/a ENCODER\=\"ffmpeg-x264\"' ./generate_commands_all.py
        run_sh="ffmpeg-x264-1p-run-all-paral.sh"
    elif [ "$encoder" = "aom" ]; then
        sed -i '/^bitstream\_folders/a ENCODER\=\"ffmpeg-libaom\"' ./generate_commands_all.py
        run_sh="ffmpeg-libaom-2p-run-all-paral.sh"
    else
        benchreps_tell_state "unsupported encoder!"
        exit 1
    fi

    low=$(echo "${levels}" | cut -d':' -f1)
    high=$(echo "${levels}" | cut -d':' -f2)
    if [ -z "${low}" ] || [ -z "${high}" ]; then
        benchreps_tell_state "Invalid input. Please enter a valid range."
        exit 1
    fi
    range="ENC_MODES = [$low"
    for i in $(seq $((low+1)) "${high}"); do
        range+=",$i"
    done
    range+="]"
    num_files=$(find ./datasets/cuts/ | wc -l)
    if [ $quick_mode -eq 1 ]; then
        # In quick mode only 1 resolution (the smallest) is used
        num_files=$(echo "$num_files" | bc -l | awk '{print int($0)}')
    else
        num_files=$(echo "$num_files * 8" | bc -l | awk '{print int($0)}')
    fi
    num_proc=$(nproc)
    if [ $procs -eq -1 ]; then
        if [ "$num_files" -lt "$num_proc" ]; then
            num_pool="num_pool = $num_files"
        else
            num_pool="num_pool = $num_proc"
        fi
    else
        num_pool="num_pool = $procs"
    fi

    echo "[PROGRESS] Encoding levels: $low to $high"
    echo "[PROGRESS] Parallel jobs: $num_pool"
    echo "[PROGRESS] Estimated files to process: $num_files"

    lp_number="lp_number = $lp"
    sed -i "/^CLIP\_DIRS/a ${lp_number}" ./generate_commands_all.py

    sed -i "/^CLIP\_DIRS/a ${range}" ./generate_commands_all.py
    sed -i "/^CLIP\_DIRS/a ${num_pool}" ./generate_commands_all.py

    #generate commands
    echo "[PROGRESS] Generating encoding commands..."
    python3 ./generate_commands_all.py
    echo "[PROGRESS] Command generation complete"

    # In quick mode, skip encoding original 1920x1080 videos (only encode downscaled versions)
    if [ $quick_mode -eq 1 ]; then
        echo "[PROGRESS] Quick mode: skipping encoding of original 1920x1080 videos"
        # Clear run_copy_reference.txt so original videos aren't copied (they won't be encoded anyway)
        > run_copy_reference.txt
        # Filter encoding commands to skip files without "to" in name (original videos don't have "to")
        for num in $(seq "${low}" "${high}"); do
            if [ -f "run-ffmpeg-svt-1p-m${num}.txt" ]; then
                # Only keep lines that have "to" in the input file path (downscaled videos)
                grep "to.*\.y4m" "run-ffmpeg-svt-1p-m${num}.txt" > "run-ffmpeg-svt-1p-m${num}.txt.tmp" && mv "run-ffmpeg-svt-1p-m${num}.txt.tmp" "run-ffmpeg-svt-1p-m${num}.txt" || true
            fi
            if [ -f "run-ffmpeg-x264-1p-m${num}.txt" ]; then
                grep "to.*\.y4m" "run-ffmpeg-x264-1p-m${num}.txt" > "run-ffmpeg-x264-1p-m${num}.txt.tmp" && mv "run-ffmpeg-x264-1p-m${num}.txt.tmp" "run-ffmpeg-x264-1p-m${num}.txt" || true
            fi
            if [ -f "run-ffmpeg-libaom-2p-m${num}.txt" ]; then
                grep "to.*\.y4m" "run-ffmpeg-libaom-2p-m${num}.txt" > "run-ffmpeg-libaom-2p-m${num}.txt.tmp" && mv "run-ffmpeg-libaom-2p-m${num}.txt.tmp" "run-ffmpeg-libaom-2p-m${num}.txt" || true
            fi
        done
    fi

    head -n -6 "./${run_sh}" > temp.sh && mv temp.sh "./${run_sh}" && chmod +x ./${run_sh}

    #run
    echo "[PROGRESS] Starting encoding jobs..."
    benchreps_tell_state "start"
    if [ "${DCPERF_PERF_RECORD}" = 1 ] && ! [ -f "perf.data" ]; then
        collect_perf_record &
    fi
    
    benchreps_tell_state "done"
    #generate output
    echo "[PROGRESS] Collecting results..."
    if [ -f "${result_filename}" ]; then
        rm "${result_filename}"
    fi

    total_size=0
    file_count=0
    for file in "${FFMPEG_ROOT}/resized_clips"/*; do
        if [ -f "$file" ]; then
            size=$(stat -c %s "$file" 2>/dev/null || echo "0")
            total_size=$((total_size + size))
            file_count=$((file_count + 1))
        fi
    done

    total_size_GB=$(echo "$total_size / 1024 / 1024 / 1024" | bc -l | awk '{printf "%.2f", $0}')

    echo "encoder=${encoder}"
    echo "total_data_encoded: ${total_size_GB} GB"
    echo "[PROGRESS] Processed $file_count video files"
    
    for num in $(seq "${low}" "${high}"); do
        filename="time_enc_${num}.log"
        if [ -f "${filename}" ]; then
            line=$(grep "Elapsed" "${filename}")
            if [ -n "$line" ]; then
                last_element=$(echo "${line}" | cut -d' ' -f 8)
                echo "res_level${num}:" "${last_element}" | tee -a "${result_filename}"
                echo "[PROGRESS] Level $num encoding time: ${last_element}"
            else
                echo "[WARNING] Could not find elapsed time in ${filename}"
            fi
        else
            echo "[WARNING] Log file ${filename} not found"
        fi
    done

    echo "[PROGRESS] Cleaning up temporary files..."
    sed -i "/^ENC/d" ./generate_commands_all.py
    delete_replicas

    echo "[PROGRESS] Benchmark complete! Results saved to ${result_filename}"
    popd

}

main "$@"

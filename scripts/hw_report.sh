#!/usr/bin/env bash

# Hardware Report v2 — Comprehensive hardware inventory in Markdown format
# Requires root/sudo

set -euo pipefail

# Locale for consistent parsing
export LANG=C
export LC_ALL=C

# --- Preamble ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script requires root. Run with sudo." >&2
    exit 2
fi

HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

echo "# Hardware Report: ${HOSTNAME}"
echo ""
echo "Generated: ${TIMESTAMP}"
echo ""

# --- Helper functions ---

# Convert bytes to human-readable (TB/GB/MB) with 2 decimal places
bytes_to_human() {
    local bytes="$1"
    if [ "${bytes}" -ge 1099511627776 ] 2>/dev/null; then
        awk -v b="${bytes}" 'BEGIN {printf "%.2f", b / 1099511627776}'
        echo " TB"
    elif [ "${bytes}" -ge 1073741824 ] 2>/dev/null; then
        awk -v b="${bytes}" 'BEGIN {printf "%.2f", b / 1073741824}'
        echo " GB"
    elif [ "${bytes}" -ge 1048576 ] 2>/dev/null; then
        awk -v b="${bytes}" 'BEGIN {printf "%.0f", b / 1048576}'
        echo " MB"
    else
        awk -v b="${bytes}" 'BEGIN {printf "%.0f", b / 1024}'
        echo " KB"
    fi
}

# Check if a command is available
cmd_available() {
    command -v "$1" &>/dev/null
}

# --- 1. System & CPU ---

echo "## System & CPU"
echo ""

# OS
os_name=""
if [ -f /etc/os-release ]; then
    os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
fi
if [ -z "${os_name}" ]; then
    os_name="Linux"
fi

# Kernel
kernel="$(uname -r)"

# Motherboard
mb_manufacturer="$(sudo dmidecode -s baseboard-manufacturer 2>/dev/null | xargs 2>/dev/null || echo 'Unknown')"
mb_product="$(sudo dmidecode -s baseboard-product-name 2>/dev/null | xargs 2>/dev/null || echo 'Unknown')"

# CPU (using lscpu for comprehensive info)
cpu_model=""
cpu_threads=""
cpu_total_cores=""
cpu_sockets=""
cpu_p_cores=""
cpu_e_cores=""
if cmd_available lscpu; then
    lscpu_output="$(lscpu 2>/dev/null || true)"
    if [ -n "${lscpu_output}" ]; then
        cpu_model="$(echo "${lscpu_output}" | awk -F': ' '/^Model name:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        cpu_threads="$(echo "${lscpu_output}" | awk -F': ' '/^CPU\(s\):/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        cpu_cores_per_socket="$(echo "${lscpu_output}" | awk -F': ' '/^Core\(s\) per socket:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        cpu_sockets="$(echo "${lscpu_output}" | awk -F': ' '/^Socket\(s\):/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"

        # Calculate total cores
        if [ -n "${cpu_cores_per_socket}" ] && [ -n "${cpu_sockets}" ]; then
            cpu_total_cores=$(( cpu_cores_per_socket * cpu_sockets ))
        else
            cpu_total_cores="${cpu_threads}"
        fi

        # Check for P/E cores (hybrid architecture)
        if echo "${lscpu_output}" | grep -qi 'performance\|efficiency'; then
            cpu_p_cores="$(echo "${lscpu_output}" | awk -F': ' '/Core\(s\) per socket \(performance\|P-core\)/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
            cpu_e_cores="$(echo "${lscpu_output}" | awk -F': ' '/Core\(s\) per socket \(efficiency\|E-core\)/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
        fi
    fi
fi

# Clean up model name (remove vendor prefix like "GenuineIntel")
if [ -n "${cpu_model}" ]; then
    cpu_model_clean="$(echo "${cpu_model}" | sed 's/^GenuineIntel //;s/^AuthenticAMD //')"
else
    cpu_model_clean="${cpu_model:-Unknown}"
fi

echo "- **OS:** ${os_name}"
echo "- **Kernel:** ${kernel}"
echo "- **Motherboard:** ${mb_manufacturer} (${mb_product})"
echo "- **CPU:** ${cpu_model_clean}"
if [ -n "${cpu_sockets}" ]; then
    echo "- **Sockets:** ${cpu_sockets}"
fi
echo "- **Cores/Threads:** ${cpu_total_cores}/${cpu_threads}"
if [ -n "${cpu_p_cores}" ] || [ -n "${cpu_e_cores}" ]; then
    echo "- **P/E Cores:** ${cpu_p_cores}P + ${cpu_e_cores}E"
fi
echo ""

# --- 2. Memory ---

echo "## Memory"
echo ""

if ! cmd_available dmidecode || ! sudo dmidecode -t memory &>/dev/null; then
    echo "dmidecode not available or no permissions to read memory info"
    echo ""
else
    echo "| Slot | Manufacturer | Model | Capacity | Speed |"
    echo "|:---|:---|:---|:---|:---|"

   sudo dmidecode -t memory | awk '
     BEGIN { FS=": "; empty="" }
     /^$/ {
         if (slot != "" && sz != "") {
             # Trim slot name to DIMM_* pattern
             gsub(/^[[:space:]]+/, "", slot)
             dimm = slot
             if (dimm !~ /DIMM/) dimm = "Generic"

             # Fallbacks for manufacturer
             if (mfr == "" || mfr ~ /<BAD|Unknown|0000|To Be|Not Specified|Empty>/) mfr = "Unknown"

             # Fallbacks for part number / model
             if (pn == "" || pn ~ /<BAD|Unknown|0000|To Be|Not Specified|Empty>/) pn = "Unknown"

             # Speed fallback
             if (speed == "" || speed == "N/A" || speed == "Unknown" || speed == "Not Specified") speed = "N/A"

             print "| " dimm " | " mfr " | " pn " | " sz " | " speed " |"
         }
         slot = ""; sz = empty; speed = ""; mfr = ""; pn = ""
         next
     }
     {
         key = $1
         val = $2
         gsub(/^[ \t]+|[ \t]+$/, "", key)
         gsub(/^[ \t]+|[ \t]+$/, "", val)
     }
     key == "Locator" || key == "Physical Memory Address" {
         if (slot == "") slot = val
     }
    key == "Size" {
         # Case-insensitive check for empty slots -- use if/else instead of ternary (mawk compatibility)
          tmpval = tolower(val)
          if (tmpval ~ /no module/) sz = ""
          else sz = val
      }
    key == "Configured Memory Speed" || key == "Configured Clock Speed" || key == "Speed" || key == "Configured Frequency" {
        if (val != "UNKNOWN" && val != "N/A" && val != "Not Specified" && val !~ /Unknown/) speed = val
    }
    key == "Manufacturer" {
        mfr = val
    }
    key == "Part Number" {
        pn = val
    }
    END {
       # empty string sentinel for no-module slots -- use if/else instead of ternary (mawk compatibility)
        if (slot != "" && sz != "") {
            gsub(/^[[:space:]]+/, "", slot)
            dimm = slot
            if (dimm !~ /DIMM/) dimm = "Generic"
            if (mfr == "" || mfr ~ /<BAD|Unknown|0000|To Be|Not Specified|Empty>/) mfr = "Unknown"
            if (pn == "" || pn ~ /<BAD|Unknown|0000|To Be|Not Specified|Empty>/) pn = "Unknown"
            if (speed == "" || speed == "N/A" || speed == "Unknown" || speed == "Not Specified") speed = "N/A"
            print "| " dimm " | " mfr " | " pn " | " sz " | " speed " |"
        }
    }
    '

    echo ""
fi

# --- 3. Swap ---

echo "## Swap"
echo ""

echo "### Traditional Swap"
echo ""
echo "| Name | Type | Size | Priority | Compression |"
echo "|:---|:---|:---|:---|:---|"

if [ -f /proc/swaps ]; then
    # Use /proc/swaps — stable column format (KB, numeric priority) across all util-linux versions.
    # swapon --show is unreliable: Ubuntu 24.04 adds an Inode column for file swaps and uses
    # human-readable sizes with locale-dependent decimal separators (e.g., "1,8M" instead of "1.8M").
    # /proc/swaps columns: Filename Type Size Used Priority (5 cols)
    tail -n +2 /proc/swaps | awk '{print $1, $2, $3, $5}' | while read -r name stype size_kb prio; do
        if [ -z "${name}" ]; then continue; fi

        # Trim fields (handle trailing whitespace from fixed-width format)
        name="$(echo "${name}" | xargs)"
        stype="$(echo "${stype}" | xargs)"
        prio="$(echo "${prio}" | xargs)"

        # Convert KB → human-readable size
        kb="${size_kb// /}"  # strip any embedded whitespace
        if [ -n "${kb}" ] && [ "${kb}" -ge 1048576 ] 2>/dev/null; then
            size_human="$(awk -v k="${kb}" 'BEGIN {printf "%.1f", k / 1048576}') GB"
        elif [ -n "${kb}" ] && [ "${kb}" -ge 1024 ] 2>/dev/null; then
            size_human="$(awk -v k="${kb}" 'BEGIN {printf "%.0f"}') MB"
        else
            size_human="${kb} KB"
        fi

        # Detect zram compression (only for /dev/zram* devices)
        comp="N/A"
        dev_base="${name#/dev/}"
        if [ -d "/sys/block/${dev_base}" ]; then
            if [ -f "/sys/block/${dev_base}/comp_algorithm" ]; then
                algo="$(cat "/sys/block/${dev_base}/comp_algorithm" 2>/dev/null | sed 's/ \[.*\]//;s/\[.*\]//')"
                if [ -n "${algo}" ] && [ "${algo}" != "none" ]; then
                    comp="${algo}"
                fi
            fi
        fi

        echo "| ${name} | ${stype} | ${size_human} | ${prio} | ${comp} |"
    done
fi

echo ""

# Zswap
echo "### Zswap"
echo ""
echo "| Enabled | Compressor | Capacity (max pool) |"
echo "|:---|:---|:---|"

zswap_enabled="$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo '')"
zswap_comp="$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo '')"
zswap_cap="N/A"

if [ -n "${zswap_enabled}" ] && [ "${zswap_enabled}" != "N" ]; then
    # Try max_pool_percent first (more reliable on newer kernels)
    max_pool_percent="$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo '')"
    if [ -n "${max_pool_percent}" ] && [ "${max_pool_percent}" -gt 0 ] 2>/dev/null; then
        # Get total RAM from /proc/meminfo
        total_ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo '')"
        if [ -n "${total_ram_kb}" ] && [ "${total_ram_kb}" -gt 0 ] 2>/dev/null; then
            total_ram_bytes=$(( total_ram_kb * 1024 ))
            pool_bytes=$(( total_ram_bytes * max_pool_percent / 100 ))
            cap_human="$(bytes_to_human "${pool_bytes}")"
        else
            cap_human="N/A"
        fi
    else
        cap_human="N/A"
    fi
fi

if [ -n "${zswap_enabled}" ]; then
    echo "| ${zswap_enabled} | ${zswap_comp} | ${cap_human} |"
else
    echo "| N/A | N/A | N/A |"
fi

echo ""

# --- 4. GPU ---

echo "## GPU"
echo ""

gpu_found=0

# NVIDIA
if cmd_available nvidia-smi; then
    nvidia_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l || echo 0)"
    if [ "${nvidia_count}" -gt 0 ] 2>/dev/null; then
        echo "| Manufacturer | GPU Name | VRAM | Driver |"
        echo "|:---|:---|:---|:---|"
        nvidia_output="$(nvidia-smi --query-gpu=name,pci.bus_id,driver_version,memory.total --format=csv,noheader,nounits 2>&1 || true)"
        if [ -n "${nvidia_output}" ] && ! echo "${nvidia_output}" | grep -qi "error\|invalid\|not found"; then
            echo "${nvidia_output}" | while IFS=',' read -r gname gpbus gdrv gmem; do
                gname="$(echo "${gname}" | xargs)"
                gpbus="$(echo "${gpbus}" | xargs)"
                gdrv="$(echo "${gdrv}" | xargs)"
                gmem="$(echo "${gmem}" | xargs)"
                vram_gb="$(awk -v m="${gmem}" 'BEGIN {printf "%.2f", m / 1024}')"
                # Trim NVIDIA manufacturer from product name (e.g., "NVIDIA GeForce RTX 2080" → "GeForce RTX 2080")
                gname_trimmed="$(echo "${gname}" | sed 's/^NVIDIA //')"
                # Get actual board producer (Subsystem) from lspci
                producer="$(sudo lspci -v -s "${gpbus}" 2>/dev/null | awk -F': ' '/Subsystem:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
                [ -z "${producer}" ] && producer="-"
                echo "| NVIDIA | ${gname_trimmed} | ${vram_gb} GB | ${gdrv} |"
            done
            echo ""
        fi
        gpu_found=1
    fi
fi

# AMD
if cmd_available rocm-smi; then
    amd_output="$(rocm-smi --showallinfo 2>/dev/null || true)"
    if [ -n "${amd_output}" ]; then
        echo "| GPU Name | Manufacturer | VRAM | Driver |"
        echo "|:---|:---|:---|:---|"
        # Parse AMD GPU info
        gpu_name="$(echo "${amd_output}" | grep -m1 'Card number\|GPU name' 2>/dev/null | sed 's/.*: //' | xargs || echo 'AMD GPU')"
        vram="$(rocm-smi --showmeminfo vram 2>/dev/null | grep 'Size' | head -1 | awk '{print $2}' | xargs || echo '0')"
        if [ -n "${vram}" ] && [ "${vram}" != "0" ]; then
            vram_gb="$(awk -v m="${vram}" 'BEGIN {printf "%.2f", m / 1024}')"
        else
            vram_gb="N/A"
        fi
        echo "| ${gpu_name} | AMD | ${vram_gb} GB | ROCm |"
        echo ""
        gpu_found=1
    fi
fi

# Intel iGPU
intel_gpu="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -i 'intel' || true)"
if [ -n "${intel_gpu}" ]; then
    # Get PCI bus address for lspci -v lookup
    igpu_bus="$(echo "${intel_gpu}" | head -1 | awk '{print $1}')"
    igpu_name="$(echo "${intel_gpu}" | head -1 | sed 's/.*: //' | sed 's/^Intel Corporation //;s/^Intel //;s/ (rev [0-9a-f]*)//' | xargs || echo 'Intel iGPU')"
    # Get actual board producer (Subsystem) from lspci -v
    igpu_producer="$(sudo lspci -v -s "${igpu_bus}" 2>/dev/null | awk -F': ' '/Subsystem:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
    [ -z "${igpu_producer}" ] && igpu_producer="-"
    # Get driver from lspci -k (more reliable than dmesg)
    igpu_driver="$(sudo lspci -s "${igpu_bus}" -k 2>/dev/null | awk -F': ' '/Kernel driver in use:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
    if [ -z "${igpu_driver}" ]; then
        igpu_driver="kernel"
    fi
    echo "| Manufacturer | GPU Name | VRAM | Driver |"
    echo "|:---|:---|:---|:---|"
    echo "| Intel | ${igpu_name} | Integrated | ${igpu_driver} |"
    echo ""
    gpu_found=1
fi

if [ "${gpu_found}" -eq 0 ]; then
    echo "No GPU detected."
    echo ""
fi

# --- 5. Storage Devices ---

echo "## Storage Devices"
echo ""

echo "| Device | Type | Model | Size | Used | Health | Notes |"
echo "|:---|:---|:---|:---|:---|:---|:---|"

if cmd_available jq && cmd_available lsblk; then
    # Use jq to filter only disk-type devices from lsblk JSON
    lsblk -Jbdo NAME,MODEL,SIZE,ROTA,TRAN,TYPE 2>/dev/null | \
        jq -r '
            [.blockdevices[] | select(.type == "disk") |
             [.name, .model // "-", .size // 0, .rota // "false", .tran // "-", .type // "-"]
            ] | .[] | @tsv
        ' 2>/dev/null | while IFS=$'\t' read -r name model size_bytes rota tran devtype; do
            path="/dev/${name}"

          # Determine type — use TRAN column for transport detection, ROTA for HDD/SSD classification
            dev_type="Unknown"
            if [ "${tran}" = "nvme" ]; then
                dev_type="NVMe"
            elif { [ -z "${rota}" ] || [ "$(echo "${rota}" | tr '[:upper:]' '[:lower:]')" != "true" ]; }; then
                # ROTA is 0, false, or empty (null from jq @tsv) → SSD/NVMe fallback
                dev_type="SSD"
           elif { [ "${rota}" = "1" ] || [ "$(echo "${rota}" | tr '[:upper:]' '[:lower:]')" = "true" ]; }; then
                dev_type="HDD"
            fi

            # Human-readable size
            size_human="$(bytes_to_human "${size_bytes}")"

            # Used space - prefer root mountpoint, fall back to first mountpoint
            used_str="-"
            used_pct="-"
            if cmd_available df; then
                # Get mountpoints for this device and its partitions
                mountpoints="$(lsblk -no MOUNTPOINT "${path}" 2>/dev/null | grep -v '^$' || true)"
                if [ -n "${mountpoints}" ]; then
                    # Prefer / mountpoint, fall back to first mountpoint
                    mountpoint="$(echo "${mountpoints}" | grep '^/$' || echo "${mountpoints}" | head -1)"
                    if [ -n "${mountpoint}" ]; then
                        df_output="$(df -B1 "${mountpoint}" 2>/dev/null | tail -1 || true)"
                        if [ -n "${df_output}" ]; then
                            total_b="$(echo "${df_output}" | awk '{print $2}')"
                            used_b="$(echo "${df_output}" | awk '{print $3}')"
                            pct="$(echo "${df_output}" | awk '{print $5}')"
                            if [ -n "${total_b}" ] && [ "${total_b}" -gt 0 ] 2>/dev/null; then
                                used_str="$(bytes_to_human "${used_b}")"
                                used_pct="${pct}"
                            fi
                        fi
                    fi
                fi
            fi

            # SMART health
            health="N/A"
            smart_output="$(sudo smartctl -H "${path}" 2>/dev/null || true)"
            if [ -n "${smart_output}" ]; then
                health="$(echo "${smart_output}" | awk -F': ' '/result/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
                [ -z "${health}" ] && health="N/A"
            fi

            # Combined smartctl call: info + attributes + health (avoids per-attribute subprocesses)
            smart_info="$(sudo smartctl -i -A -H "${path}" 2>/dev/null || true)"

            # Manufacturer from cached output — Vendor: first, then Model Family
            manufacturer="$(echo "${smart_info}" | awk -F': ' '/^Vendor:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' | xargs || true)"
            if [ -z "${manufacturer}" ] || [ "${manufacturer}" = "-" ]; then
                mfr_family="$(echo "${smart_info}" | awk -F': ' '/^Model Family:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' | xargs || true)"
                if [ -n "${mfr_family}" ]; then
                    case "${mfr_family}" in
                        "Western Digital"*) manufacturer="Western Digital" ;;
                        "Samsung"*) manufacturer="Samsung" ;;
                        "HGST"*) manufacturer="HGST" ;;
                        "Seagate"*) manufacturer="Seagate" ;;
                        "Toshiba"*) manufacturer="Toshiba" ;;
                        "Crucial"*) manufacturer="Crucial" ;;
                        "Kingston"*) manufacturer="Kingston" ;;
                        *) manufacturer="$(echo "${mfr_family}" | awk '{print $1}')" ;;
                    esac
                fi
            fi
            # Fallback: derive from device model prefix
            if [ -z "${manufacturer}" ] || [ "${manufacturer}" = "-" ]; then
                case "${model}" in
                    WDC*|WD*) manufacturer="Western Digital" ;;
                    Samsung*) manufacturer="Samsung" ;;
                    HGST*) manufacturer="HGST" ;;
                    Seagate*) manufacturer="Seagate" ;;
                    TOSHIBA*) manufacturer="Toshiba" ;;
                    CRUCIAL*) manufacturer="Crucial" ;;
                    Kingston*) manufacturer="Kingston" ;;
                    *) manufacturer="-" ;;
                esac
            fi
            [ -z "${manufacturer}" ] && manufacturer="-"

        # Notes (SMART details) — separate by device type to avoid cross-contamination
            notes=""

         if [ "${tran}" = "nvme" ]; then
                # NVMe: use nvme smart-log for wear percentage (Samsung 960 PRO uses this)
                is_nvme=1
                nvme_log="$(sudo nvme smart-log "${path}" 2>/dev/null || true)"
                wear="$(echo "${nvme_log}" | awk '/percentage_used/ {gsub(/%/, "", $NF); print $NF}' || true)"
          else
                # SSD: use ATA SMART table (Samsung 850 uses Wear_Leveling_Count column $4 = remaining %)
                is_nvme=0
            fi

            if [ ${is_nvme} -eq 1 ] && [ -n "${wear}" ]; then
                notes="Wear: ${wear}%"
          elif { [ -z "${notes}" ] || [ "${notes}" = "-" ]; }; then
                # SSD wear leveling — normalized column $4 (matches hw_report.sh)
                if [ "${dev_type}" = "SSD" ]; then
                    wear_attr="$(echo "${smart_info}" | awk '/Wear_Leveling_Count|Percent_Lifetime_Used/ {print $4}' | tr -dc '0-9' | head -1 || true)"
                    if [ -n "${wear_attr}" ] && [[ $((10#${wear_attr})) -gt 0 ]] 2>/dev/null; then
                        # Wear_Leveling_Count VALUE is remaining life % (higher = less wear, can exceed 100)  
                        # Percent_Lifetime_Used VALUE is used percentage (lower = more worn)
                        if [[ $((10#${wear_attr})) -le 100 ]]; then
                            notes="Wear: $((100 - 10#${wear_attr}))%"
                        else
                            :  # Value > 100 means healthy drive, no wear note needed  
                        fi
                    fi
                fi
            fi

          # HDD/SSD/NVMe: check SMART attributes for notable values (always runs)  
            local_notes=""

           if [ "${dev_type}" = "HDD" ]; then
               # SMART failure indicators for HDD: reallocated sectors, pending bad blocks, uncorrectable errors  
                realloc="$(echo "${smart_info}" | awk '/Reallocated_Sector_Ct/ {print $NF}' | tr -dc '0-9' || true)"
                if [ -n "${realloc}" ] && [[ $((10#${realloc})) -gt 0 ]] 2>/dev/null; then
                    local_notes="${local_notes}Reallocated_Sector_Ct ${realloc},"
                fi

                pending="$(echo "${smart_info}" | awk '/Current_Pending_Sector/ {print $NF}' | tr -dc '0-9' || true)"
                if [ -n "${pending}" ] && [[ $((10#${pending})) -gt 0 ]] 2>/dev/null; then
                    local_notes="${local_notes}Current_Pending_Sector ${pending},"
                fi

                offline="$(echo "${smart_info}" | awk '/Offline_Uncorrectable/ {print $NF}' | tr -dc '0-9' || true)"
                if [ -n "${offline}" ] && [[ $((10#${offline})) -gt 0 ]] 2>/dev/null; then
                    local_notes="${local_notes}Offline_Uncorrectable ${offline},"
                fi
                
            elif [ ${is_nvme} -eq 0 ]; then
                # SATA SSD: SMART failure indicators (Reallocated_Sector_Ct only — no wear, that's separate)  
                realloc="$(echo "${smart_info}" | awk '/Reallocated_Sector_Ct/ {print $NF}' | tr -dc '0-9' || true)"
                if [ -n "${realloc}" ] && [[ $((10#${realloc})) -gt 0 ]] 2>/dev/null; then
                    local_notes="${local_notes}Reallocated_Sector_Ct ${realloc},"
                fi
                
            else
                # NVMe: media errors (wear is handled separately)  
                media_err="$(echo "${nvme_log}" | awk '/media_errors/ {gsub(/[^0-9]/,"",$NF); print $NF}' || true)"
                if [ -n "${media_err}" ] && [[ $((10#${media_err})) -gt 0 ]] 2>/dev/null; then
                    local_notes="${local_notes}Media_Errors ${media_err},"
                fi
            fi

           # Apply notes: strip trailing comma, combine with existing wear data or fallback to dash  
            if [ -n "${local_notes}" ]; then
                local_notes="$(echo "${local_notes}" | sed 's/,$//')"
                if [[ ${is_nvme} -eq 1 ]]; then
                    # NVMe: append additional checks to wear or use standalone
                    if [[ "${notes}" == Wear:* ]]; then
                        notes="${notes}; ${local_notes}"
                    else
                        notes="${local_notes}"
                    fi
                elif [ -z "${notes}" ] || [ "${notes}" = "-" ]; then
                    # No existing data — use local_notes (SMART issues found)  
                    notes="${local_notes}"
                else
                    # Append to existing wear data (SSD with wear but also SMART issues)
                    notes="${notes}; ${local_notes}"
                fi
            elif [ -z "${notes}" ] || [ "${notes}" = "-" ]; then
                # Nothing meaningful — set dash  
                notes="-"
            fi

            echo "| ${path} | ${dev_type} | ${model} | ${size_human} | ${used_str} (${used_pct}) | ${health} | ${notes} |"
        done
fi

echo ""

# RAID arrays
if [ -f /proc/mdstat ]; then
    echo "### RAID Arrays"
    echo ""
    echo "| Name | Level | State | Active/Total | Size | Devices |"
    echo "|:---|:---|:---|:---|:---|:---|"

    current_name=""
    current_level=""
    current_state=""
    current_devices=""
    current_size=""
    current_active=0
    current_total=0

    flush_md() {
        if [ -n "${current_name}" ]; then
            echo "| ${current_name} | ${current_level} | ${current_state} | ${current_active}/${current_total} | ${current_size} | ${current_devices} |"
        fi
    }

    while IFS= read -r line; do
        if [[ "${line}" =~ ^md[0-9]+[[:space:]]+:[[:space:]]+(.*) ]]; then
            flush_md
            current_name="$(echo "${line}" | awk '{print $1}')"
            rest="${BASH_REMATCH[1]}"
            current_state="$(echo "${rest}" | awk '{print $1}')"
            current_level="$(echo "${rest}" | awk '{print $2}')"
            # Extract device names from first line (format: sda1[0] sdb1[1] sdc1[2])
            # Extract device names (strip [N] suffix) — POSIX-compatible (avoids grep -P dependency).
            # Only process fields containing brackets to avoid capturing non-device words like "active" or "raid5".
            current_devices="$(echo "${rest}" | awk '{for(i=1;i<=NF;i++){if($i ~ /\[.+\]/){gsub(/\[.*/, "", $i); print $i}}}' | paste -sd, -)"
            current_size=""
            current_active=0
            current_total=0
            continue
        fi
        if [[ "${line}" =~ \[ ]]; then
            if [[ "${line}" =~ ([0-9]+)[[:space:]]+blocks ]]; then
                blocks_val="${BASH_REMATCH[1]}"
                bytes=$((blocks_val * 1024))
                if [ "${bytes}" -ge 1099511627776 ] 2>/dev/null; then
                    current_size="$(awk -v b="${bytes}" 'BEGIN {printf "%.2f", b / 1099511627776}') TB"
                elif [ "${bytes}" -ge 1073741824 ] 2>/dev/null; then
                    current_size="$(awk -v b="${bytes}" 'BEGIN {printf "%.2f", b / 1073741824}') GB"
                else
                    current_size="$(awk -v b="${bytes}" 'BEGIN {printf "%.0f", b / 1048576}') MB"
                fi
            fi
            if [[ "${line}" =~ \[([U\.\-]+)\] ]]; then
                uu_str="${BASH_REMATCH[1]}"
                current_total=${#uu_str}
                current_active="$(echo "${uu_str}" | tr -cd 'U' | wc -c)"
            fi
        fi
    done < /proc/mdstat

    flush_md
fi

echo ""

# --- 6. Network Interfaces ---

echo "## Network Interfaces"
echo ""

echo "| Interface | Model | Link Speed | IP Address | Status |"
echo "|:---|:---|:---|:---|:---|"

ip -br addr show 2>/dev/null | grep -vE "lo|veth|docker|br-|virbr|vnet|tun|tap|ww" | sort | while read -r line; do
    ifname="$(echo "${line}" | awk '{print $1}')"
    status="$(echo "${line}" | awk '{print $2}')"
    ipaddr="$(echo "${line}" | awk '{print $3}')"
    [ -z "${ipaddr}" ] && ipaddr="-"

    # Link speed via ethtool
    link_speed="-"
    if cmd_available ethtool; then
        eth_output="$(sudo ethtool "${ifname}" 2>/dev/null || true)"
        if [ -n "${eth_output}" ]; then
            speed="$(echo "${eth_output}" | awk '/Speed:/{gsub(/^[ \t]+/,""); print $2; exit}' || true)"
            max_speed="$(echo "${eth_output}" | awk '/Max Speed:/{gsub(/^[ \t]+/,""); print $3; exit}' || true)"
           if [ "${speed}" = "Unknown!" ]; then
                link_speed="-"
            elif [ -n "${max_speed}" ] && [ "${speed}" != "${max_speed}" ]; then
                link_speed="${speed} (max: ${max_speed})"
            elif [ -n "${speed}" ]; then
                link_speed="${speed}"
            fi
        fi
    fi

    # Get Model from lspci -v Subsystem (board manufacturer + device name)
    model="-"
    if cmd_available lspci; then
        _sysfs="$(readlink "/sys/class/net/${ifname}/device" 2>/dev/null || true)"
        if [ -n "${_sysfs}" ]; then
            # PCI address pattern: dddd:bb:ss.f — use grep -oE (POSIX ERE, portable)
            _full_pci="$(echo "${_sysfs}" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' || true)"
        fi
        if [ -n "${_full_pci}" ]; then
            _pci_short="$(echo "${_full_pci}" | sed 's/^0000://')"
            # Get Subsystem from lspci -v (contains board manufacturer + device name)
            _subsys="$(sudo lspci -v -s "${_pci_short}" 2>/dev/null | awk -F': ' '/Subsystem:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true)"
            if [ -n "${_subsys}" ]; then
                model="${_subsys}"
            else
                # Fallback: device description from lspci -nn
                _lspci_nn="$(sudo lspci -nn -s "${_pci_short}" 2>/dev/null || true)"
                if [ -n "${_lspci_nn}" ]; then
                    model="$(echo "${_lspci_nn}" | sed 's/^[^ ]* //' | sed 's/ \[.*\].*$//' | sed 's/ (rev [0-9a-f]*)//' | xargs)"
                fi
            fi
        fi
    fi
    [ -z "${model}" ] && model="Physical Adapter"

    echo "| ${ifname} | ${model} | ${link_speed} | ${ipaddr} | ${status} |"
done

echo ""

#!/bin/bash

export LANG=en_DK.UTF-8 2>/dev/null || true

echo "# Hardware Report: $(hostname)"
echo "Generated on: $(date +'%Y-%m-%d %H:%M:%S')"
echo ""

echo "## 🖥️ System & CPU"
MOBO=$(sudo dmidecode -s baseboard-product-name | xargs)
[[ "$MOBO" == "To Be Filled By O.E.M." ]] && MOBO="Generic OEM Board"
CPU=$(lscpu | grep 'Model name' | head -n1 | cut -d: -f2 | xargs)
echo "Stack: **$MOBO** | **$CPU**"
echo ""

echo "## 🧠 RAM Configuration"
echo "| Slot | Size | Speed | Details |"
echo "|:---|:---|:---|:---|"
sudo dmidecode -t 17 | awk '
    BEGIN {FS=": "; OFS=" | "}
    /Locator:/ {slot=$2}
    /Size:/ {size=$2}
    /Configured Memory Speed:/ {speed=$2}
    /Manufacturer:/ {man=$2}
    /Part Number:/ {pn=$2}
    /Rank:/ {
        if (size !~ /No Module/ && size != "") {
            if (man ~ /Unknown|0000|To Be Filled/) man="Generic"
            if (pn ~ /Unknown|0000|To Be Filled/) pn="-"
            gsub(/ +$/, "", speed); gsub(/ +$/, "", man); gsub(/ +$/, "", pn);
            printf "| %s | %s | %s | %s (%s) |\n", slot, size, speed, man, pn
        }
        slot=size=speed=man=pn=""
    }
'
echo ""

echo "## 🎮 Graphics (GPU)"
echo "| Device | Driver |"
echo "|:---|:---|"
lspci -nn | grep -E 'VGA|3D' | while read -r line; do
    gpu=$(echo "$line" | cut -d: -f3 | sed 's/ \[.*//' | xargs)
    pci_id=$(echo "$line" | awk '{print $1}')
    driver=$(lspci -k -s "$pci_id" | grep "Kernel driver" | cut -d: -f2 | xargs)
    echo "| $gpu | ${driver:-n/a} |"
done
echo ""

echo "## 🌐 Network Interfaces"
echo "| Interface | Model | Status | IP Address |"
echo "|:---|:---|:---|:---|"
lspci -nn | grep -i net | while read -r line; do
    pci_id=$(echo "$line" | awk '{print $1}')
    model=$(echo "$line" | cut -d: -f3 | sed 's/ \[.*//' | xargs)
    ifname=$(ls /sys/bus/pci/devices/0000:"$pci_id"/net 2>/dev/null | head -n1)
    if [ -n "$ifname" ]; then
        state=$(ip addr show "$ifname" | grep -oP 'state \K\w+')
        ip_addr=$(ip addr show "$ifname" | grep -oP 'inet \K[\d.]+' | head -n1)
        echo "| $ifname | $model | $state | ${ip_addr:--} |"
    else
        echo "| - | $model | No Driver | - |"
    fi
done
echo ""

echo "## 💾 Storage Devices"
echo "| Device | Model | Size | Type | Health | Notes |"
echo "|:---|:---|:---|:---|:---|:---|"

lsblk -dno NAME,MODEL,SIZE,ROTA --output-delimiter=$'\x01' | grep -E "sd|nvme" | while IFS=$'\x01' read -r name model size rota; do
    dev="/dev/$name"
    model_clean=$(echo "$model" | xargs)
    
    [[ "$rota" == "1" ]] && type="HDD" || type="SSD/NVMe"
    
    health=$(sudo smartctl -H "$dev" | grep -i "result" | cut -d: -f2 | xargs)
    [[ -z "$health" ]] && health="N/A"
    
    notes="OK"
    if [[ "$name" == nvme* ]]; then
        usage=$(sudo nvme smart-log "$dev" 2>/dev/null | awk '/percentage_used/ {print $3}')
        [[ -n "$usage" ]] && notes="Wear: $usage"
    else
        errors=$(sudo smartctl -A "$dev" | awk '/Offline_Uncorrectable/ {print $10}')
        [[ -n "$errors" && "$errors" -gt 0 ]] && notes="⚠️ $errors Errors"
        
        if [[ "$type" == "SSD/NVMe" ]]; then
            wear_val=$(sudo smartctl -A "$dev" | awk '/Wear_Leveling_Count|Percent_Lifetime_Used|Life_Left/ {print $4}' | grep -oE '[0-9]+' | head -n1)
            if [ -n "$wear_val" ]; then
                if [ 10#$wear_val -le 100 ]; then
                    notes="Wear: $((100 - 10#$wear_val))%"
                fi
            fi
        fi
    fi
    echo "| $dev | $model_clean | $size | $type | $health | $notes |"
done

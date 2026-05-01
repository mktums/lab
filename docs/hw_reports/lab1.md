# Hardware Report: lab1

Generated: 2026-05-01 05:29:12 UTC

## System & CPU

- **OS:** Ubuntu 24.04.4 LTS
- **Kernel:** 6.8.0-110-generic
- **Motherboard:** ASRock (X299 Taichi XE)
- **CPU:** Intel(R) Core(TM) i7-7820X CPU @ 3.60GHz
- **Sockets:** 1
- **Cores/Threads:** 8/16

## Memory

| Slot | Manufacturer | Model | Capacity | Speed |
|:---|:---|:---|:---|:---|
| CPU1_DIMM_A0 | Unknown | Unknown | 16 GB | 2133 MT/s |
| CPU1_DIMM_B0 | Unknown | Unknown | 16 GB | 2133 MT/s |

## Swap

### Traditional Swap

| Name | Type | Size | Priority | Compression |
|:---|:---|:---|:---|:---|
| /swap.img | file | 8.0 GB | -2 | N/A |

### Zswap

| Enabled | Compressor | Capacity (max pool) |
|:---|:---|:---|
| Y | zstd | 7.76 GB |

## GPU

| Manufacturer | GPU Name | VRAM | Driver |
|:---|:---|:---|:---|
| NVIDIA | GeForce RTX 2080 | 8.00 GB | 590.48.01 |

## Storage Devices

| Device | Type | Model | Size | Used | Health | Notes |
|:---|:---|:---|:---|:---|:---|:---|
| /dev/sda | HDD | WDC WD30EFRX-68A | 2.73 TB | 316.74 GB (6%) | PASSED | - |
| /dev/sdb | HDD | WDC WD30EFRX-68A | 2.73 TB | 316.74 GB (6%) | PASSED | Offline_Uncorrectable 2 |
| /dev/sdc | HDD | WDC WD30EFRX-68A | 2.73 TB | 316.74 GB (6%) | PASSED | - |
| /dev/sdd | HDD | WDC WD10EARS-00Y | 931.51 GB | 32 KB (1%) | PASSED | - |
| /dev/nvme0n1 | NVMe | Samsung SSD 960 PRO 512GB | 476.94 GB | 45.56 GB (11%) | PASSED | Wear: 21% |

### RAID Arrays

| Name | Level | State | Active/Total | Size | Devices |
|:---|:---|:---|:---|:---|:---|
| md0 | raid5 | active | 3/3 | 5.46 TB | sdc1,sdb1,sda1 |

## Network Interfaces

| Interface | Model | Link Speed | IP Address | Status |
|:---|:---|:---|:---|:---|
| eno1 | ASRock Incorporation Ethernet Connection (2) I219-V | 1000Mb/s | 10.10.10.10/24 | UP |
| enp5s0 | ASRock Incorporation I211 Gigabit Network Connection | - | - | DOWN |
| wlp4s0 | Intel Corporation Dual Band Wireless-AC 3168NGW [Stone Peak] | - | - | DOWN |
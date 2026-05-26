from __future__ import annotations

import os
import platform
import subprocess
from pathlib import Path

from _native import dependency_root, load_config, project_root


def ps(cmd: str) -> str:
    p = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
        capture_output=True,
        text=True,
    )
    return (p.stdout or "").strip()


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    dep = dependency_root(root, cfg)
    ov_root = dep / "openvino"

    print("=== OS ===")
    os_details = ps(
        "$os = Get-CimInstance Win32_OperatingSystem; "
        "if (-not $os) { '' } else { "
        "$out = @(); "
        "$out += \"Platform: {0}\" -f [System.Environment]::OSVersion.VersionString; "
        "$out += \"Caption: $($os.Caption)\"; "
        "$out += \"Version: $($os.Version)\"; "
        "$out += \"BuildNumber: $($os.BuildNumber)\"; "
        "$out += \"Architecture: $($os.OSArchitecture)\"; "
        "$out -join [Environment]::NewLine }"
    )
    print(os_details or platform.platform())
    print()

    print("=== CPU ===")
    cpu_query = """
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$bb = Get-CimInstance Win32_BaseBoard | Select-Object -First 1

if (-not $cpu) {
    ''
} else {
    $out = @()
    if ($cs) {
        $out += "SystemModel: $($cs.Model)"
        $out += "SystemType: $($cs.SystemType)"
        $out += "SystemSKU: $($cs.SystemSKUNumber)"
    }

    $procSummary = "$($cpu.Name), $($cpu.MaxClockSpeed) Mhz, $($cpu.NumberOfCores) Core(s), $($cpu.NumberOfLogicalProcessors) Logical Processor(s)"
    $out += "Processor: $procSummary"
    $out += "ProcessorManufacturer: $($cpu.Manufacturer)"
    $out += "ProcessorId: $($cpu.ProcessorId)"

    if ($bb) {
        $out += "BaseBoardManufacturer: $($bb.Manufacturer)"
        $out += "BaseBoardProduct: $($bb.Product)"
    }

    $out -join [Environment]::NewLine
}
"""
    cpu_details = ps(cpu_query)
    print(cpu_details or (platform.processor() or "Unknown"))
    print()

    print("=== GPU DETAILS ===")
    gpu = ps(
        "$rows = Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion; "
        "if (-not $rows) { '' } else { "
        "$out = @(); "
        "foreach ($r in $rows) { "
        "$out += \"Name: $($r.Name)\"; "
        "$out += \"DriverVersion: $($r.DriverVersion)\"; "
        "$out += ''; "
        "}; "
        "$out -join [Environment]::NewLine }"
    )
    print(gpu or "N/A")
    print()

    print("=== NPU DETAILS ===")
    npu_query = """
$npu = Get-PnpDevice |
    Where-Object {
        $_.FriendlyName -and
        $_.FriendlyName -match 'NPU|Neural|AI Boost|Intel\\(R\\) NPU' -and
        $_.FriendlyName -notmatch '^USB Input Device'
    } |
    Sort-Object FriendlyName -Unique

if (-not $npu) {
    ''
} else {
    $rows = foreach ($d in $npu) {
        $drv = Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceID -eq $d.InstanceId } |
            Select-Object -First 1

        $driverDate = 'N/A'
        $dateProp = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverDate' -ErrorAction SilentlyContinue
        if ($dateProp -and $dateProp.Data) {
            try {
                $driverDate = (Get-Date $dateProp.Data).ToString('yyyy-MM-dd')
            } catch {
                $driverDate = [string]$dateProp.Data
            }
        } elseif ($drv -and $drv.DriverDate) {
            try {
                $driverDate = [Management.ManagementDateTimeConverter]::ToDateTime($drv.DriverDate).ToString('yyyy-MM-dd')
            } catch {
                $driverDate = [string]$drv.DriverDate
            }
        }

        "Name: $($d.FriendlyName)"
        "DriverVersion: $(if ($drv) { $drv.DriverVersion } else { 'N/A' })"
        "DriverDate: $driverDate"
        ""
    }
    $rows -join [Environment]::NewLine
}
"""
    npu = ps(npu_query)
    print(npu or "NPU Status: Not detected")

    print("=== OPENVINO DETAILS ===")
    print(f"Configured Location: {ov_root}")
    setup = list(ov_root.rglob("setupvars.bat")) if ov_root.exists() else []
    if setup:
        sv = setup[-1]
        print("Setupvars: Found")
        vfile = sv.parent / "runtime" / "version.txt"
        if vfile.is_file():
            print(f"OpenVINO Version: {vfile.read_text(encoding='utf-8', errors='ignore').splitlines()[0].strip()}")
        else:
            print("OpenVINO Version: N/A")
    else:
        print("Setupvars: Missing under configured location")
        print("OpenVINO Version: N/A")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

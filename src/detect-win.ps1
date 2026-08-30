# aura-overlay window scanner. Visible, titled, non-tool, non-cloaked
# top-level windows only. Emits one compressed JSON line per scan:
# [{ hwnd, pid, process }] - titles are used ONLY as a liveness filter and
# never emitted (CLAUDE.md rule 8: titles can hold prompt text).
# Default: one scan, exit. -Loop: read commands from stdin ("scan" emits a
# scan line, "exit" or EOF quits) so the brain spawns ONE powershell for
# its whole life instead of one per 2 s cycle (rule 7: CPU budget).
param([switch]$Loop)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class AuraOverlayDetect {
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    public struct Row { public long Hwnd; public uint Pid; }

    public static List<Row> Scan() {
        List<Row> rows = new List<Row>();
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            if (!IsWindowVisible(h)) return true;
            int ex = GetWindowLong(h, -20);
            if ((ex & 0x80) != 0) return true;                 // WS_EX_TOOLWINDOW (our rings included)
            int cloaked;
            if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;  // DWMWA_CLOAKED
            StringBuilder sb = new StringBuilder(512);
            GetWindowTextW(h, sb, 512);
            if (sb.Length == 0) return true;                   // untitled: not user-facing
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            Row r = new Row(); r.Hwnd = (long)h; r.Pid = pid;
            rows.Add(r);
            return true;
        }, IntPtr.Zero);
        return rows;
    }
}
'@

function Get-ScanJson {
    $procs = @{}
    foreach ($p in Get-Process) { $procs[[int64]$p.Id] = $p.ProcessName }
    $rows = [AuraOverlayDetect]::Scan()
    $out = @()
    foreach ($row in $rows) {
        $key = [int64]$row.Pid
        if (-not $procs.ContainsKey($key)) { continue }        # process gone mid-scan
        $out += [pscustomobject]@{ hwnd = $row.Hwnd; pid = $row.Pid; process = $procs[$key] }
    }
    return (ConvertTo-Json -InputObject $out -Compress)
}

if ($Loop) {
    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { break }     # stdin closed: the brain is gone
        if ($line -eq 'exit') { break }
        if ($line -eq 'scan') {
            # null = failed scan (the brain keeps its last rings); '[]' would
            # read as a real empty desktop and destroy every ring
            $json = 'null'
            try { $json = Get-ScanJson } catch { $json = 'null' }
            [Console]::Out.WriteLine($json)
            [Console]::Out.Flush()
        }
    }
} else {
    [Console]::Out.WriteLine((Get-ScanJson))
}

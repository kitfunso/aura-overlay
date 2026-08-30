# aura-overlay renderer: multi-ring host (MVP Step 2).
# Raw Win32 only (CLAUDE.md rule 3): every ring window is created with
# WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
# WS_EX_TOPMOST at CreateWindowEx time. A message-only host window owns a
# WM_TIMER tick that (a) reloads rings.json when its mtime changes and
# reconciles create/destroy/recolor, (b) tracks every ring's target rect
# (DWMWA_EXTENDED_FRAME_BOUNDS), hides on minimize, destroys on target
# death or pid mismatch (hwnds recycle; rings.json entries carry the pid
# that owned the hwnd when the brain saw it).
# rings.json shape: [{"hwnd": 123, "pid": 456, "hex": "26bbd9"}, ...]
param(
    [string]$RingsFile = "$env:LOCALAPPDATA\aura-overlay\rings.json",
    [int]$PollMs = 30,
    [int]$Thickness = 3,
    [int]$MaxMinutes = 0    # 0 = run until stopped; tests pass a cap
)
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies @('System', 'System.Core', 'System.Web.Extensions') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;

namespace AuraOverlay {
public static class RingHost {
    private delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX {
        public uint cbSize; public uint style; public WndProc lpfnWndProc;
        public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
        public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWindowExW(uint exStyle, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] private static extern int GetMessageW(out MSG msg, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessageW(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr SetTimer(IntPtr h, IntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool InvalidateRect(IntPtr h, IntPtr rect, bool erase);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] private static extern int FillRect(IntPtr dc, ref RECT rect, IntPtr brush);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateSolidBrush(int color);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] private static extern int CombineRgn(IntPtr dest, IntPtr a, IntPtr b, int mode);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr o);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT rect, int size);

    private const uint WM_TIMER = 0x0113;
    private const uint WM_DESTROY = 0x0002;
    private const uint WM_ERASEBKGND = 0x0014;

    private class Ring {
        public IntPtr Hwnd;       // the ring window we own
        public IntPtr Target;     // the window it follows (NOT ours; read-only)
        public uint Pid;
        public string Hex;
        public IntPtr Brush;
        public bool Shown;
        public RECT Last;
        public bool HaveLast;
    }

    private static WndProc procRef;   // held so the GC never collects the delegate
    private static IntPtr host;
    private static IntPtr hInstance;
    private static string className = "AuraOverlayRing";
    private static string ringsPath;
    private static int thickness;
    private static DateTime deadline;
    private static DateTime lastMtime = DateTime.MinValue;
    private static Dictionary<long, Ring> rings = new Dictionary<long, Ring>();
    private static JavaScriptSerializer json = new JavaScriptSerializer();

    private static IntPtr Proc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_TIMER && hWnd == host) { Tick(); return IntPtr.Zero; }
        if (msg == WM_ERASEBKGND) {
            foreach (Ring ring in rings.Values) {
                if (ring.Hwnd == hWnd) {
                    RECT rc;
                    if (GetClientRect(hWnd, out rc)) FillRect(wParam, ref rc, ring.Brush);
                    return (IntPtr)1;
                }
            }
        }
        if (msg == WM_DESTROY && hWnd == host) { PostQuitMessage(0); return IntPtr.Zero; }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static int ColorRefFromHex(string hex) {
        string s = hex.TrimStart('#');
        int r = Convert.ToInt32(s.Substring(0, 2), 16);
        int g = Convert.ToInt32(s.Substring(2, 2), 16);
        int b = Convert.ToInt32(s.Substring(4, 2), 16);
        return (b << 16) | (g << 8) | r;   // COLORREF is 0x00BBGGRR
    }

    private static bool PidOwnsWindow(IntPtr target, uint pid) {
        uint actual;
        GetWindowThreadProcessId(target, out actual);
        return actual == pid;
    }

    private static void DestroyRing(long key) {
        Ring ring;
        if (!rings.TryGetValue(key, out ring)) return;
        rings.Remove(key);
        DestroyWindow(ring.Hwnd);
        DeleteObject(ring.Brush);
    }

    private static void CreateRing(long key, uint pid, string hex) {
        IntPtr target = (IntPtr)key;
        // hwnds recycle: never ring a window the entry's pid does not own.
        if (!IsWindow(target) || !PidOwnsWindow(target, pid)) return;
        uint ex = 0x80000u | 0x20u | 0x80u | 0x8u | 0x8000000u;  // LAYERED|TRANSPARENT|TOOLWINDOW|TOPMOST|NOACTIVATE
        IntPtr hwnd = CreateWindowExW(ex, className, "", 0x80000000u /* WS_POPUP */,
            0, 0, 10, 10, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) return;
        SetLayeredWindowAttributes(hwnd, 0, 255, 2);  // LWA_ALPHA, fully opaque
        Ring ring = new Ring();
        ring.Hwnd = hwnd; ring.Target = target; ring.Pid = pid; ring.Hex = hex;
        ring.Brush = CreateSolidBrush(ColorRefFromHex(hex));
        rings[key] = ring;        // registered BEFORE show so WM_ERASEBKGND finds the brush
        UpdateRing(key, ring);
    }

    private static void RecolorRing(Ring ring, string hex) {
        IntPtr old = ring.Brush;
        ring.Brush = CreateSolidBrush(ColorRefFromHex(hex));
        ring.Hex = hex;
        DeleteObject(old);
        InvalidateRect(ring.Hwnd, IntPtr.Zero, true);
    }

    private static void UpdateRing(long key, Ring ring) {
        if (!IsWindow(ring.Target) || !PidOwnsWindow(ring.Target, ring.Pid)) { DestroyRing(key); return; }
        if (IsIconic(ring.Target)) {
            if (ring.Shown) { ShowWindow(ring.Hwnd, 0); ring.Shown = false; }  // SW_HIDE
            return;
        }
        RECT r;
        // DWMWA_EXTENDED_FRAME_BOUNDS (9): the VISUAL rect; GetWindowRect floats.
        if (DwmGetWindowAttribute(ring.Target, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) return;
        if (!ring.HaveLast || r.Left != ring.Last.Left || r.Top != ring.Last.Top || r.Right != ring.Last.Right || r.Bottom != ring.Last.Bottom) {
            ring.Last = r; ring.HaveLast = true;
            int t = thickness;
            int x = r.Left - t, y = r.Top - t;
            int w = (r.Right - r.Left) + 2 * t, h = (r.Bottom - r.Top) + 2 * t;
            SetWindowPos(ring.Hwnd, IntPtr.Zero, x, y, w, h, 0x10 | 0x4);  // NOACTIVATE | NOZORDER
            IntPtr rgn = CreateRectRgn(0, 0, w, h);
            IntPtr inner = CreateRectRgn(t, t, w - t, h - t);
            CombineRgn(rgn, rgn, inner, 4);  // RGN_DIFF: the border ring only
            DeleteObject(inner);
            SetWindowRgn(ring.Hwnd, rgn, true);  // the system owns rgn from here
        }
        if (!ring.Shown) { ShowWindow(ring.Hwnd, 8); ring.Shown = true; }  // SW_SHOWNA
    }

    private static void Reconcile(string text) {
        object parsed = json.DeserializeObject(text);
        object[] list = parsed as object[];
        if (list == null) return;
        Dictionary<long, Ring> desired = new Dictionary<long, Ring>();  // Ring reused as a value bag
        foreach (object o in list) {
            Dictionary<string, object> d = o as Dictionary<string, object>;
            if (d == null || !d.ContainsKey("hwnd") || !d.ContainsKey("pid") || !d.ContainsKey("hex")) continue;
            try {
                Ring want = new Ring();
                want.Target = (IntPtr)Convert.ToInt64(d["hwnd"]);
                want.Pid = Convert.ToUInt32(d["pid"]);
                want.Hex = Convert.ToString(d["hex"]);
                desired[(long)want.Target] = want;   // duplicate hwnds: last wins
            } catch { }                              // one bad entry never kills the set
        }
        List<long> gone = new List<long>();
        foreach (long key in rings.Keys) { if (!desired.ContainsKey(key)) gone.Add(key); }
        foreach (long key in gone) DestroyRing(key);
        foreach (KeyValuePair<long, Ring> kv in desired) {
            Ring have;
            if (rings.TryGetValue(kv.Key, out have)) {
                if (have.Pid != kv.Value.Pid) { DestroyRing(kv.Key); CreateRing(kv.Key, kv.Value.Pid, kv.Value.Hex); }
                else if (have.Hex != kv.Value.Hex) RecolorRing(have, kv.Value.Hex);
            } else {
                CreateRing(kv.Key, kv.Value.Pid, kv.Value.Hex);
            }
        }
    }

    private static void CheckRingsFile() {
        try {
            if (!File.Exists(ringsPath)) return;   // missing file: keep last state
            DateTime mtime = File.GetLastWriteTimeUtc(ringsPath);
            if (mtime == lastMtime) return;
            string text = File.ReadAllText(ringsPath);
            Reconcile(text);          // throws on bad JSON -> retried next tick
            lastMtime = mtime;
        } catch { }                   // fail silent (rule 6); state unchanged
    }

    private static void Tick() {
        if (DateTime.UtcNow > deadline) { Quit(); return; }
        CheckRingsFile();
        List<long> keys = new List<long>(rings.Keys);
        foreach (long key in keys) {
            Ring ring;
            if (rings.TryGetValue(key, out ring)) UpdateRing(key, ring);
        }
    }

    private static void Quit() {
        List<long> keys = new List<long>(rings.Keys);
        foreach (long key in keys) DestroyRing(key);
        DestroyWindow(host);          // WM_DESTROY on host posts the quit
    }

    public static int Run(string ringsFile, int pollMs, int borderPx, int maxMinutes) {
        SetProcessDPIAware();
        ringsPath = ringsFile;
        thickness = borderPx;
        deadline = (maxMinutes > 0) ? DateTime.UtcNow.AddMinutes(maxMinutes) : DateTime.MaxValue;

        procRef = Proc;
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = procRef;
        hInstance = Marshal.GetHINSTANCE(typeof(RingHost).Module);
        wc.hInstance = hInstance;
        wc.hbrBackground = IntPtr.Zero;   // per-ring brush painted in WM_ERASEBKGND
        wc.lpszClassName = className;
        if (RegisterClassExW(ref wc) == 0) return 2;

        // message-only host window (parent HWND_MESSAGE): owns the timer, never shows.
        host = CreateWindowExW(0, className, "aura-overlay-host", 0, 0, 0, 0, 0, (IntPtr)(-3), IntPtr.Zero, hInstance, IntPtr.Zero);
        if (host == IntPtr.Zero) return 3;
        SetTimer(host, (IntPtr)1, (uint)pollMs, IntPtr.Zero);

        MSG msg;
        while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
        // rings die with the process anyway (a window cannot outlive its
        // thread), but leave nothing to chance on the clean path either.
        List<long> keys = new List<long>(rings.Keys);
        foreach (long key in keys) DestroyRing(key);
        return 0;
    }
}
}
'@

$code = [AuraOverlay.RingHost]::Run($RingsFile, $PollMs, $Thickness, $MaxMinutes)
exit $code

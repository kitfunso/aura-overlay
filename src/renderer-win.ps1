# aura-overlay renderer: raw Win32 multi-ring host (CLAUDE.md rule 3) plus
# tray icon, hotkeys, and brain lifecycle. Full design: docs/ARCHITECTURE.md.
param(
    [string]$RingsFile = "$env:LOCALAPPDATA\aura-overlay\rings.json",
    [int]$PollMs = 30,
    [int]$Thickness = 3,
    [int]$MaxMinutes = 0,   # 0 = run until stopped; tests pass a cap
    [switch]$NoBrain        # tests drive rings.json by hand
)
$ErrorActionPreference = 'Stop'

# Singleton: one renderer per desktop session. A second start exits quietly
# with one local log line (rule 6: never intrude, not even with an error box).
$script:singletonMutex = New-Object System.Threading.Mutex($false, 'Local\AuraOverlayRenderer')
$acquired = $false
try { $acquired = $script:singletonMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    $runtimeDir = Split-Path -Parent $RingsFile
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    Add-Content -Path (Join-Path $runtimeDir 'renderer.log') -Value ("{0} start skipped: another renderer holds the mutex" -f (Get-Date -Format s))
    exit 0
}

Add-Type -ReferencedAssemblies @('System', 'System.Core', 'System.Web.Extensions') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
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
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA {
        public uint cbSize; public IntPtr hWnd; public uint uID; public uint uFlags;
        public uint uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState; public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
    }

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
    [DllImport("user32.dll")] private static extern IntPtr BeginDeferWindowPos(int count);
    [DllImport("user32.dll")] private static extern IntPtr DeferWindowPos(IntPtr ctx, IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll")] private static extern bool EndDeferWindowPos(IntPtr ctx);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr h, uint cmd);
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
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIconW(uint msg, ref NOTIFYICONDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadIconW(IntPtr inst, IntPtr name);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern int TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr owner, IntPtr rect);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string name);

    private const uint WM_TIMER = 0x0113;
    private const uint WM_DESTROY = 0x0002;
    private const uint WM_ERASEBKGND = 0x0014;
    private const uint WM_TRAY = 0x8001;         // WM_APP + 1: tray callback
    private const uint WM_HOTKEY = 0x0312;
    private const uint MENU_ID_QUIT = 1;
    private const int HOTKEY_ID_TAG = 1;         // Ctrl+Alt+G
    private const int HOTKEY_ID_UNTAG = 2;       // Ctrl+Alt+U

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
    private static string stopFlagPath;
    private static string logPath;
    private static NOTIFYICONDATA trayData;
    private static bool trayShown;
    private static uint taskbarCreatedMsg;   // broadcast when Explorer (re)starts
    private static bool tagsDirty;           // a failed tags.json save retries next tick

    private class Tag { public long Hwnd; public uint Pid; public long TaggedAt; }
    private static string tagsPath;
    private static List<Tag> tags = new List<Tag>();
    private static IntPtr deferCtx;   // one DeferWindowPos transaction per tick; zero outside Tick's update loop

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
        if (msg == WM_TRAY && hWnd == host) {
            long evt = lParam.ToInt64() & 0xFFFF;
            if (evt == 0x0205 || evt == 0x007B) ShowTrayMenu();   // WM_RBUTTONUP or WM_CONTEXTMENU
            return IntPtr.Zero;
        }
        if (msg == WM_HOTKEY && hWnd == host) {
            long id = wParam.ToInt64();
            if (id == HOTKEY_ID_TAG) TagForeground();
            if (id == HOTKEY_ID_UNTAG) UntagForeground();
            return IntPtr.Zero;
        }
        // Explorer restart kills every tray icon; re-add it here. The zero
        // guard avoids a false match against WM_NULL (unregistered id 0).
        if (taskbarCreatedMsg != 0 && msg == taskbarCreatedMsg && hWnd == host) {
            trayShown = Shell_NotifyIconW(0, ref trayData);   // NIM_ADD
            Log(trayShown ? "tray icon re-added after Explorer restart" : "tray icon re-add FAILED");
            return IntPtr.Zero;
        }
        if (msg == WM_DESTROY && hWnd == host) { PostQuitMessage(0); return IntPtr.Zero; }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static void Log(string line) {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + line + Environment.NewLine); } catch { }
    }

    // The only SetForegroundWindow in this codebase, on our own hidden host
    // window: without it the tray popup menu never dismisses (MS KB135788).
    private static void ShowTrayMenu() {
        IntPtr menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        AppendMenuW(menu, 0, (UIntPtr)MENU_ID_QUIT, "Quit aura-overlay");
        POINT pt;
        GetCursorPos(out pt);
        SetForegroundWindow(host);
        int cmd = TrackPopupMenu(menu, 0x100 | 0x2, pt.X, pt.Y, 0, host, IntPtr.Zero);  // TPM_RETURNCMD | TPM_RIGHTBUTTON
        PostMessageW(host, 0, IntPtr.Zero, IntPtr.Zero);   // WM_NULL, same KB
        DestroyMenu(menu);
        if (cmd == (int)MENU_ID_QUIT) Quit();
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
        // NOT topmost (CLAUDE.md rule 3): a ring belongs to its target's own
        // z-order. KeepAboveTarget below does the pinning.
        uint ex = 0x80000u | 0x20u | 0x80u | 0x8000000u;  // LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE
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
            int t = thickness;
            // Only a SIZE change rebuilds the region; a pure MOVE keeps shape.
            // Rebuilding every move measured too costly (docs/ARCHITECTURE.md).
            bool sizeChanged = !ring.HaveLast
                || (r.Right - r.Left) != (ring.Last.Right - ring.Last.Left)
                || (r.Bottom - r.Top) != (ring.Last.Bottom - ring.Last.Top);
            ring.Last = r; ring.HaveLast = true;
            int x = r.Left - t, y = r.Top - t;
            int w = (r.Right - r.Left) + 2 * t, h = (r.Bottom - r.Top) + 2 * t;
            uint flags = 0x10u | 0x4u;               // NOACTIVATE | NOZORDER
            if (!sizeChanged) flags |= 0x1u;         // SWP_NOSIZE
            // Inside the tick, moves join ONE DeferWindowPos transaction:
            // 7 dragging rings cost one composition pass, not seven.
            if (deferCtx != IntPtr.Zero && !sizeChanged) {
                IntPtr next = DeferWindowPos(deferCtx, ring.Hwnd, IntPtr.Zero, x, y, w, h, flags);
                if (next != IntPtr.Zero) deferCtx = next;
                else SetWindowPos(ring.Hwnd, IntPtr.Zero, x, y, w, h, flags);
            } else {
                SetWindowPos(ring.Hwnd, IntPtr.Zero, x, y, w, h, flags);
            }
            if (sizeChanged) {
                IntPtr rgn = CreateRectRgn(0, 0, w, h);
                IntPtr inner = CreateRectRgn(t, t, w - t, h - t);
                CombineRgn(rgn, rgn, inner, 4);      // RGN_DIFF: the border ring only
                DeleteObject(inner);
                SetWindowRgn(ring.Hwnd, rgn, true);  // the system owns rgn from here
            }
        }
        if (!ring.Shown) { ShowWindow(ring.Hwnd, 8); ring.Shown = true; }  // SW_SHOWNA
        KeepAboveTarget(ring);
    }

    // Pin the ring immediately above its target in z-order every tick
    // (docs/ARCHITECTURE.md); GW_HWNDPREV (3) makes the steady state cheap.
    private static void KeepAboveTarget(Ring ring) {
        if (GetWindow(ring.Target, 3) == ring.Hwnd) return;
        uint flags = 0x1u | 0x2u | 0x10u;  // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        SetWindowPos(ring.Hwnd, ring.Target, 0, 0, 0, 0, flags);
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
                // Bad hex must throw HERE: in CreateRing it would leak an
                // hwnd and re-abort Reconcile every tick (lastMtime stuck).
                ColorRefFromHex(want.Hex);
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

    // Tagging (renderer-owned side): this process is the ONLY writer of
    // tags.json. The brain freezes each tag's identity into its own file.
    private static void LoadTags() {
        tags = new List<Tag>();
        try {
            if (!File.Exists(tagsPath)) return;
            object parsed = json.DeserializeObject(File.ReadAllText(tagsPath));
            object[] list = parsed as object[];
            if (list == null) return;
            foreach (object o in list) {
                Dictionary<string, object> d = o as Dictionary<string, object>;
                if (d == null || !d.ContainsKey("hwnd") || !d.ContainsKey("pid") || !d.ContainsKey("taggedAt")) continue;
                try {
                    Tag t = new Tag();
                    t.Hwnd = Convert.ToInt64(d["hwnd"]);
                    t.Pid = Convert.ToUInt32(d["pid"]);
                    t.TaggedAt = Convert.ToInt64(d["taggedAt"]);
                    tags.Add(t);
                } catch { }
            }
        } catch { }
    }

    private static void SaveTags() {
        tagsDirty = true;
        FlushTags();
    }

    private static void FlushTags() {
        if (!tagsDirty) return;
        try {
            List<object> list = new List<object>();
            foreach (Tag t in tags) {
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["hwnd"] = t.Hwnd; d["pid"] = t.Pid; d["taggedAt"] = t.TaggedAt;
                list.Add(d);
            }
            string tmp = tagsPath + ".tmp";
            File.WriteAllText(tmp, json.Serialize(list));
            // File.Replace is atomic: the brain must never see a missing
            // file mid-write (it would wrongly prune every frozen identity).
            if (File.Exists(tagsPath)) File.Replace(tmp, tagsPath, null);
            else File.Move(tmp, tagsPath);
            tagsDirty = false;
        } catch { }
        // Still dirty: a sharing violation from the brain's read. Tick
        // retries FlushTags 30 ms later, so a tag is never lost to it.
    }

    private static bool IsOurWindow(IntPtr h) {
        StringBuilder sb = new StringBuilder(64);
        GetClassNameW(h, sb, 64);
        return sb.ToString() == className;
    }

    private static long NowUnixMs() {
        return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
    }

    private static void TagForeground() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero || fg == host || IsOurWindow(fg)) return;
        uint pid;
        GetWindowThreadProcessId(fg, out pid);
        if (pid == 0) return;
        foreach (Tag t in tags) { if (t.Hwnd == (long)fg && t.Pid == pid) return; }   // already tagged
        Tag tag = new Tag();
        tag.Hwnd = (long)fg; tag.Pid = pid; tag.TaggedAt = NowUnixMs();
        tags.Add(tag);
        SaveTags();
        Log("tagged hwnd " + tag.Hwnd + " pid " + tag.Pid);
    }

    private static void UntagForeground() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return;
        int removed = tags.RemoveAll(delegate(Tag t) { return t.Hwnd == (long)fg; });
        if (removed > 0) { SaveTags(); Log("untagged hwnd " + (long)fg); }
    }

    private static void PruneTags() {
        int removed = tags.RemoveAll(delegate(Tag t) {
            IntPtr h = (IntPtr)t.Hwnd;
            return !IsWindow(h) || !PidOwnsWindow(h, t.Pid);
        });
        if (removed > 0) { SaveTags(); Log("pruned " + removed + " dead tag(s)"); }
    }

    private static void Tick() {
        if (File.Exists(stopFlagPath)) {          // launcher --stop: same polled-file pattern as rings.json
            try { File.Delete(stopFlagPath); } catch { }
            Quit(); return;
        }
        if (DateTime.UtcNow > deadline) { Quit(); return; }
        CheckRingsFile();
        PruneTags();
        FlushTags();   // retry a save that lost a sharing race last tick
        List<long> keys = new List<long>(rings.Keys);
        deferCtx = (keys.Count > 0) ? BeginDeferWindowPos(keys.Count) : IntPtr.Zero;
        foreach (long key in keys) {
            Ring ring;
            if (rings.TryGetValue(key, out ring)) UpdateRing(key, ring);
        }
        if (deferCtx != IntPtr.Zero && !EndDeferWindowPos(deferCtx)) {
            // a failed transaction (e.g. a ring destroyed mid-tick) dropped
            // this tick's moves: force a re-apply on the next tick
            foreach (Ring rr in rings.Values) rr.HaveLast = false;
        }
        deferCtx = IntPtr.Zero;
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
        string runtimeDir = Path.GetDirectoryName(Path.GetFullPath(ringsFile));
        stopFlagPath = Path.Combine(runtimeDir, "stop.flag");
        logPath = Path.Combine(runtimeDir, "renderer.log");
        try { File.Delete(stopFlagPath); } catch { }   // a stale flag must not kill a fresh start

        procRef = Proc;
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = procRef;
        hInstance = Marshal.GetHINSTANCE(typeof(RingHost).Module);
        wc.hInstance = hInstance;
        wc.hbrBackground = IntPtr.Zero;   // per-ring brush painted in WM_ERASEBKGND
        wc.lpszClassName = className;
        if (RegisterClassExW(ref wc) == 0) return 2;

        // Hidden top-level host (not message-only): SetForegroundWindow for
        // the tray menu requires a real window, which message-only is not.
        host = CreateWindowExW(0x80 /* TOOLWINDOW */, className, "aura-overlay-host", 0x80000000u /* WS_POPUP */, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (host == IntPtr.Zero) return 3;
        SetTimer(host, (IntPtr)1, (uint)pollMs, IntPtr.Zero);

        trayData = new NOTIFYICONDATA();
        trayData.cbSize = (uint)Marshal.SizeOf(typeof(NOTIFYICONDATA));
        trayData.hWnd = host;
        trayData.uID = 1;
        trayData.uFlags = 0x1 | 0x2 | 0x4;   // NIF_MESSAGE | NIF_ICON | NIF_TIP
        trayData.uCallbackMessage = WM_TRAY;
        trayData.hIcon = LoadIconW(IntPtr.Zero, (IntPtr)32512);   // IDI_APPLICATION
        trayData.szTip = "aura-overlay";
        trayShown = Shell_NotifyIconW(0, ref trayData);           // NIM_ADD; failure is cosmetic (rule 6)
        Log(trayShown ? "tray icon added" : "tray icon add FAILED");
        taskbarCreatedMsg = RegisterWindowMessageW("TaskbarCreated");

        tagsPath = Path.Combine(runtimeDir, "tags.json");
        LoadTags();
        PruneTags();   // windows that died while we were not running
        // MOD_NOREPEAT | MOD_CONTROL | MOD_ALT. A taken hotkey is logged and
        // ignored (rule 6): rings and the other key still work.
        if (!RegisterHotKey(host, HOTKEY_ID_TAG, 0x4000 | 0x2 | 0x1, 0x47))
            Log("hotkey Ctrl+Alt+G registration FAILED (already taken elsewhere)");
        if (!RegisterHotKey(host, HOTKEY_ID_UNTAG, 0x4000 | 0x2 | 0x1, 0x55))
            Log("hotkey Ctrl+Alt+U registration FAILED (already taken elsewhere)");

        MSG msg;
        while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
        // rings die with the process anyway (a window cannot outlive its
        // thread), but leave nothing to chance on the clean path either.
        List<long> keys = new List<long>(rings.Keys);
        foreach (long key in keys) DestroyRing(key);
        UnregisterHotKey(host, HOTKEY_ID_TAG);
        UnregisterHotKey(host, HOTKEY_ID_UNTAG);
        if (trayShown) Shell_NotifyIconW(2, ref trayData);   // NIM_DELETE
        Log("clean exit");
        return 0;
    }
}
}
'@

# Brain child shares the renderer's lifetime: killed on clean exit; the
# brain's own --parent-pid watchdog is the backstop if the renderer crashes.
$brainProc = $null
if (-not $NoBrain) {
    $brainScript = Join-Path $PSScriptRoot 'brain.js'
    try {
        $brainProc = Start-Process node -ArgumentList @(('"' + $brainScript + '"'), '--parent-pid', $PID) -WindowStyle Hidden -PassThru
    } catch {
        # no node on PATH: rings still render from the last rings.json.
        # Log it, or "no rings ever update" has no visible cause anywhere.
        $brainProc = $null
        try {
            $rtDir = Split-Path -Parent $RingsFile
            Add-Content -Path (Join-Path $rtDir 'renderer.log') -Value ("{0} brain spawn FAILED: {1}" -f (Get-Date -Format s), $_.Exception.Message)
        } catch { }
    }
}

$code = [AuraOverlay.RingHost]::Run($RingsFile, $PollMs, $Thickness, $MaxMinutes)

if ($brainProc) {
    try { if (-not $brainProc.HasExited) { Stop-Process -Id $brainProc.Id -Force } } catch { }
}
try { [void]$script:singletonMutex.ReleaseMutex() } catch { }
exit $code

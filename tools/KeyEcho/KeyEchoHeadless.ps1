# KeyEcho without a window, for runs driven from another machine.
#
# Installs the same low-level keyboard hook as KeyEcho.exe and appends the
# same JSON Lines - one metadata row, then one row per event - to a file, so
# tools/KeyEcho/analyze-keyecho.sh judges it unchanged. Needs nothing but
# Windows PowerShell 5.1: the hook is compiled with Add-Type.
#
# It has to run in the RDP user's interactive session, where the keys
# arrive - over SSH that means a scheduled task with /IT:
#
#   schtasks /Create /TN KeyEcho /SC ONCE /ST 00:00 /IT /F /TR ^
#     "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\KeyEcho\KeyEchoHeadless.ps1 -Path C:\KeyEcho\keyecho.jsonl"
#   schtasks /Run /TN KeyEcho
#
# With -IncludeMouse it also records mouse buttons and wheel turns (not
# moves) as rows of "type":"mouse", for pointer checks; analyze-keyecho.sh
# expects keyboard rows only, so use it for separate runs.
#
# Stop it with `schtasks /End /TN KeyEcho` or by deleting -StopFile.
# Test-only, like KeyEcho.exe: it records every key.
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$StopFile = "$Path.running",
    [switch]$IncludeMouse
)

$source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class KeyEchoHeadless {
    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    const uint LLKHF_EXTENDED = 0x01, LLKHF_INJECTED = 0x10, LLKHF_ALTDOWN = 0x20, LLKHF_UP = 0x80;

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public int x, y; public uint mouseData, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern int GetKeyNameText(int lParam, StringBuilder name, int size);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

    static HookProc proc, mouseProc;
    static StreamWriter writer;
    static long sequence;

    static string Hex(uint value) { return "0x" + value.ToString("X2"); }
    static string Json(string value) {
        var text = new StringBuilder("\"");
        foreach (var c in value) {
            if (c == '"' || c == '\\') text.Append('\\').Append(c);
            else if (c < 0x20) text.AppendFormat("\\u{0:X4}", (int)c);
            else text.Append(c);
        }
        return text.Append('"').ToString();
    }

    static IntPtr Hook(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            var e = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            var name = new StringBuilder(64);
            int keyParam = (int)((e.scanCode << 16) | ((e.flags & LLKHF_EXTENDED) != 0 ? (1u << 24) : 0u));
            GetKeyNameText(keyParam, name, name.Capacity);
            long ns = (long)(Stopwatch.GetTimestamp() * (1e9 / Stopwatch.Frequency));
            writer.WriteLine("{\"type\":\"event\",\"sequence\":" + (++sequence)
                + ",\"monotonic_ns\":" + ns
                + ",\"action\":\"" + ((e.flags & LLKHF_UP) != 0 ? "up" : "down")
                + "\",\"scan_code\":\"" + Hex(e.scanCode)
                + "\",\"extended\":" + ((e.flags & LLKHF_EXTENDED) != 0 ? "true" : "false")
                + ",\"vk_code\":\"" + Hex(e.vkCode)
                + "\",\"vk_name\":" + Json(name.ToString())
                + ",\"injected\":" + ((e.flags & LLKHF_INJECTED) != 0 ? "true" : "false")
                + ",\"alt_down\":" + ((e.flags & LLKHF_ALTDOWN) != 0 ? "true" : "false")
                + "}");
            writer.Flush();
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    static IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            string action = null;
            switch ((int)wParam) {
                case 0x201: action = "left-down"; break;
                case 0x202: action = "left-up"; break;
                case 0x204: action = "right-down"; break;
                case 0x205: action = "right-up"; break;
                case 0x207: action = "middle-down"; break;
                case 0x208: action = "middle-up"; break;
                case 0x20A: action = "wheel"; break;
                case 0x20E: action = "hwheel"; break;
            }
            if (action != null) {
                var e = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                long ns = (long)(Stopwatch.GetTimestamp() * (1e9 / Stopwatch.Frequency));
                int delta = action.EndsWith("wheel") ? (short)(e.mouseData >> 16) : 0;
                writer.WriteLine("{\"type\":\"mouse\",\"sequence\":" + (++sequence)
                    + ",\"monotonic_ns\":" + ns + ",\"action\":\"" + action
                    + "\",\"x\":" + e.x + ",\"y\":" + e.y + ",\"wheel\":" + delta + "}");
                writer.Flush();
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    public static void Run(string path, string stopFile, string windows, bool includeMouse) {
        writer = new StreamWriter(path, false, new UTF8Encoding(false));
        writer.WriteLine("{\"type\":\"metadata\",\"keyecho_version\":\"headless-1\",\"computer\":"
            + Json(Environment.MachineName) + ",\"windows\":" + Json(windows)
            + ",\"clock\":\"QueryPerformanceCounter\"}");
        writer.Flush();
        proc = Hook;
        var hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("SetWindowsHookEx failed");
        if (includeMouse) {
            mouseProc = MouseHook;
            if (SetWindowsHookEx(WH_MOUSE_LL, mouseProc, GetModuleHandle(null), 0) == IntPtr.Zero)
                throw new InvalidOperationException("SetWindowsHookEx (mouse) failed");
        }
        File.WriteAllText(stopFile, "");
        // A low-level hook is called on this thread's message loop, so it has
        // to keep pumping; the stop file ends the run without killing it.
        while (File.Exists(stopFile)) {
            MSG msg;
            while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
            System.Threading.Thread.Sleep(5);
        }
        writer.Dispose();
    }
}
"@

Add-Type -TypeDefinition $source -Language CSharp
$windows = (Get-CimInstance Win32_OperatingSystem).Version
[KeyEchoHeadless]::Run($Path, $StopFile, $windows, $IncludeMouse.IsPresent)

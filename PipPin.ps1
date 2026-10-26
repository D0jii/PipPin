# PipPin - pin any window as a small always-on-top box over a game.
# No dependencies. Windows PowerShell 5.1 + .NET Framework only.
#
# Hotkeys (all Ctrl+Alt+...):
#   P  pin / unpin the FOCUSED window (and remember it as the target)
#   G  grab the window UNDER THE MOUSE as the target, and pin it
#   S  cycle size          C  cycle corner
#   T  cycle transparency  H  hide / restore the target
#   N  open Netflix in a frameless Edge window and auto-pin it
#   A  open Amazon Prime Video in a frameless Edge window and auto-pin it
#   Q  quit
#
# Once a target is remembered, S/C/T/H keep working while the GAME has focus.
# The pinned window's title bar hides itself and reappears while the mouse is over it.

# Single instance - a second launch exits quietly instead of fighting over hotkeys.
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\PipPin_SingleInstance')
if (-not $script:mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class PipPin : Form
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int index, int val);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hWnd, ref Point p);
    [DllImport("user32.dll")] private static extern int SetWindowRgn(IntPtr hWnd, IntPtr rgn, bool redraw);
    [DllImport("user32.dll")] private static extern int GetWindowRgn(IntPtr hWnd, IntPtr rgn);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr param);

    private const int WM_HOTKEY = 0x0312;
    private const int GWL_EXSTYLE = -20;
    private const int GWL_STYLE = -16;
    private const int WS_CAPTION = 0x00C00000;
    private const int WS_EX_LAYERED = 0x00080000;
    private const uint LWA_ALPHA = 0x2;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_FRAMECHANGED = 0x0020;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint GA_ROOT = 2;
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    private static readonly Size[] Sizes = new Size[] {
        new Size(360, 202), new Size(440, 248), new Size(520, 292),
        new Size(640, 360), new Size(800, 450)
    };
    // Corner order: top-left, top-right, bottom-right, bottom-left.
    private static readonly byte[] Alphas = new byte[] { 255, 235, 205, 170, 135 };
    private const int Gap = 12;

    private IntPtr target = IntPtr.Zero;
    private bool pinned = false;
    private int sizeIdx = 1;
    private int cornerIdx = 0;
    private int alphaIdx = 0;
    private NotifyIcon tray;
    private Timer hunter;
    private int hunterTicks = 0;
    private string huntMatch = "";
    private string huntLabel = "";
    // Auto-hide title bar: shown while the mouse is over the pinned window, hidden 5s after it leaves.
    private Timer hover;
    private bool targetHadCaption = false;
    private DateTime captionUntil = DateTime.MinValue;
    private const int CaptionLingerMs = 5000;
    // Edge/Chrome draw their title bar inside the window, so it is hidden by clipping
    // the top strip off with a window region. Height in 100%-scale pixels.
    private const int BrowserCaptionDip = 33;
    private bool clipped = false;
    private int clipW = 0, clipH = 0;
    private readonly List<string> failures = new List<string>();

    public static void MakeDpiAware() { try { SetProcessDPIAware(); } catch { } }

    private static Icon LoadIcon()
    {
        try
        {
            string path = System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(Application.ExecutablePath), "PipPin.ico");
            if (!System.IO.File.Exists(path)) path = IconPath;
            if (System.IO.File.Exists(path)) return new Icon(path);
        }
        catch { }
        return SystemIcons.Application;
    }

    public static string IconPath = "";

    public PipPin()
    {
        this.ShowInTaskbar = false;
        this.WindowState = FormWindowState.Minimized;
        this.FormBorderStyle = FormBorderStyle.FixedToolWindow;
        this.Load += delegate { this.Hide(); };

        tray = new NotifyIcon();
        tray.Icon = LoadIcon();
        tray.Text = "PipPin - Ctrl+Alt+P to pin a window";
        tray.Visible = true;
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Show hotkeys", null, delegate { ShowHelp(); });
        menu.Items.Add("Open Netflix window", null, delegate { LaunchNetflix(); });
        menu.Items.Add("Open Prime Video window", null, delegate { LaunchPrime(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { Quit(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { ShowHelp(); };

        Reg(1, 0x50, "Ctrl+Alt+P");   // P
        Reg(2, 0x47, "Ctrl+Alt+G");   // G
        Reg(3, 0x53, "Ctrl+Alt+S");   // S
        Reg(4, 0x43, "Ctrl+Alt+C");   // C
        Reg(5, 0x54, "Ctrl+Alt+T");   // T
        Reg(6, 0x48, "Ctrl+Alt+H");   // H
        Reg(7, 0x4E, "Ctrl+Alt+N");   // N
        Reg(8, 0x51, "Ctrl+Alt+Q");   // Q
        Reg(9, 0x41, "Ctrl+Alt+A");   // A

        if (failures.Count > 0)
            Notify("Some hotkeys are taken", string.Join(", ", failures.ToArray()) + " could not be registered (another app owns them).");
        else
            Notify("PipPin running", "Ctrl+Alt+P pins the focused window. Ctrl+Alt+Q quits.");
    }

    protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }

    private void Reg(int id, uint vk, string label)
    {
        if (!RegisterHotKey(this.Handle, id, 0x0002 | 0x0001, vk)) failures.Add(label); // MOD_CONTROL | MOD_ALT
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            switch (m.WParam.ToInt32())
            {
                case 1: TogglePin(GetForegroundWindow()); break;
                case 2: TogglePin(GetAncestor(WindowFromPoint(Cursor.Position), GA_ROOT)); break;
                case 3: if (Alive()) { sizeIdx = (sizeIdx + 1) % Sizes.Length; Apply(); } break;
                case 4: if (Alive()) { cornerIdx = (cornerIdx + 1) % 4; Apply(); } break;
                case 5: if (Alive()) { alphaIdx = (alphaIdx + 1) % Alphas.Length; ApplyAlpha(); } break;
                case 6: ToggleHide(); break;
                case 7: LaunchNetflix(); break;
                case 8: Quit(); break;
                case 9: LaunchPrime(); break;
            }
            return;
        }
        base.WndProc(ref m);
    }

    private bool Alive() { return target != IntPtr.Zero && IsWindow(target); }

    private static string TitleOf(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    private void TogglePin(IntPtr h)
    {
        if (h == IntPtr.Zero || !IsWindow(h)) return;
        if (h == this.Handle) return;

        if (pinned && h == target)
        {
            ReleaseCaption();
            SetWindowPos(target, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            alphaIdx = 0; ApplyAlpha();
            pinned = false;
            tray.Text = "PipPin - nothing pinned";
            Notify("Unpinned", TitleOf(h));
            return;
        }

        BeginPin(h);
        string t = TitleOf(h);
        tray.Text = "PipPin - pinned: " + (t.Length > 50 ? t.Substring(0, 50) : t);
        Notify("Pinned", t + "\nCtrl+Alt+S size, C corner, T fade, H hide.");
    }

    private void BeginPin(IntPtr h)
    {
        if (h != target) ReleaseCaption();
        target = h;
        pinned = true;
        // Only auto-hide windows that actually have a title bar; never add one to a borderless window.
        targetHadCaption = (GetWindowLong(h, GWL_STYLE) & WS_CAPTION) == WS_CAPTION;
        captionUntil = DateTime.Now.AddMilliseconds(CaptionLingerMs);
        Apply();
        ApplyAlpha();
        if (hover == null)
        {
            hover = new Timer();
            hover.Interval = 150;
            hover.Tick += delegate { HoverTick(); };
        }
        hover.Start();
    }

    private void HoverTick()
    {
        if (!pinned || !targetHadCaption || !Alive() || IsIconic(target)) return;
        RECT r;
        if (!GetWindowRect(target, out r)) return;
        Point p = Cursor.Position;
        bool over = p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom;
        if (over) captionUntil = DateTime.Now.AddMilliseconds(CaptionLingerMs);
        SetCaption(DateTime.Now < captionUntil);
    }

    private void SetCaption(bool show)
    {
        if (!Alive()) return;
        if (show)
        {
            if (clipped) { SetWindowRgn(target, IntPtr.Zero, true); clipped = false; }
            return;
        }
        RECT r;
        if (!GetWindowRect(target, out r)) return;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        // The browser drops our region when it resizes, so re-clip if it went missing.
        if (clipped && w == clipW && h == clipH && HasRegion()) return;
        IntPtr rgn = CreateRectRgn(0, CaptionHeight(r), w, h);
        if (SetWindowRgn(target, rgn, true) != 0) { clipped = true; clipW = w; clipH = h; }
        else DeleteObject(rgn);
    }

    private bool HasRegion()
    {
        IntPtr tmp = CreateRectRgn(0, 0, 0, 0);
        int type = GetWindowRgn(target, tmp);
        DeleteObject(tmp);
        return type != 0; // 0 = ERROR = no region set
    }

    private int CaptionHeight(RECT r)
    {
        Point p = new Point(0, 0);
        ClientToScreen(target, ref p);
        int inset = p.Y - r.Top;
        if (inset >= 15) return inset;   // normal app: title bar sits above the client area
        int dpi = 96;
        try { dpi = (int)GetDpiForWindow(target); } catch { }
        if (dpi <= 0) dpi = 96;
        return inset + (int)Math.Round(BrowserCaptionDip * dpi / 96.0);
    }

    // Put the title bar back before letting go of a window.
    private void ReleaseCaption()
    {
        if (clipped && Alive()) SetWindowRgn(target, IntPtr.Zero, true);
        clipped = false;
        targetHadCaption = false;
    }

    private void Apply()
    {
        if (!Alive()) return;
        Rectangle wa = Screen.FromHandle(target).WorkingArea;
        Size s = Sizes[sizeIdx];
        int x, y;
        switch (cornerIdx)
        {
            case 1:  x = wa.Right - s.Width - Gap;  y = wa.Top + Gap; break;
            case 2:  x = wa.Right - s.Width - Gap;  y = wa.Bottom - s.Height - Gap; break;
            case 3:  x = wa.Left + Gap;             y = wa.Bottom - s.Height - Gap; break;
            default: x = wa.Left + Gap;             y = wa.Top + Gap; break;
        }
        SetWindowPos(target, HWND_TOPMOST, x, y, s.Width, s.Height, SWP_NOACTIVATE);
    }

    private void ApplyAlpha()
    {
        if (!Alive()) return;
        int ex = GetWindowLong(target, GWL_EXSTYLE);
        byte a = Alphas[alphaIdx];
        if (a == 255)
        {
            // Drop the layered style entirely at full opacity - safest for DRM video.
            SetWindowLong(target, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
            SetWindowPos(target, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        else
        {
            SetWindowLong(target, GWL_EXSTYLE, ex | WS_EX_LAYERED);
            SetLayeredWindowAttributes(target, 0, a, LWA_ALPHA);
        }
    }

    private void ToggleHide()
    {
        if (!Alive()) return;
        if (IsIconic(target)) { ShowWindow(target, 9); Apply(); ApplyAlpha(); }  // SW_RESTORE
        else ShowWindow(target, 6);                                             // SW_MINIMIZE
    }

    private void LaunchNetflix() { LaunchStream("https://www.netflix.com/browse", "Netflix", "Netflix"); }

    // primevideo.com redirects to amazon.com/gp/video in the US; both titles contain "Prime Video".
    private void LaunchPrime() { LaunchStream("https://www.primevideo.com", "Prime Video", "Prime Video"); }

    private void LaunchStream(string url, string match, string label)
    {
        string[] candidates = new string[] {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) + @"\Microsoft\Edge\Application\msedge.exe",
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + @"\Microsoft\Edge\Application\msedge.exe",
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + @"\Google\Chrome\Application\chrome.exe",
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) + @"\Google\Chrome\Application\chrome.exe"
        };
        string exe = null;
        for (int i = 0; i < candidates.Length; i++)
            if (System.IO.File.Exists(candidates[i])) { exe = candidates[i]; break; }
        if (exe == null) { Notify("No browser found", "Could not locate Edge or Chrome."); return; }

        Size s = Sizes[sizeIdx];
        try
        {
            Process.Start(exe, "--app=" + url + " --window-size=" + s.Width + "," + s.Height);
        }
        catch (Exception ex) { Notify("Launch failed", ex.Message); return; }

        huntMatch = match;
        huntLabel = label;
        hunterTicks = 0;
        if (hunter == null)
        {
            hunter = new Timer();
            hunter.Interval = 500;
            hunter.Tick += delegate { HuntWindow(); };
        }
        hunter.Start();
    }

    private void HuntWindow()
    {
        hunterTicks++;
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h)) return true;
            string t = TitleOf(h);
            if (t.IndexOf(huntMatch, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);

        if (found != IntPtr.Zero)
        {
            hunter.Stop();
            BeginPin(found);
            tray.Text = "PipPin - pinned: " + huntLabel;
            Notify(huntLabel + " pinned", "Ctrl+Alt+S size, C corner, T fade, H hide.");
        }
        else if (hunterTicks > 60) // give up after ~30s
        {
            hunter.Stop();
            Notify("Could not find the " + huntLabel + " window", "Focus it and press Ctrl+Alt+P to pin it manually.");
        }
    }

    private void ShowHelp()
    {
        MessageBox.Show(
            "Ctrl+Alt+P   pin / unpin the focused window\n" +
            "Ctrl+Alt+G   pin the window under the mouse\n" +
            "Ctrl+Alt+S   cycle size\n" +
            "Ctrl+Alt+C   cycle corner\n" +
            "Ctrl+Alt+T   cycle transparency\n" +
            "Ctrl+Alt+H   hide / restore\n" +
            "Ctrl+Alt+N   open a Netflix window and pin it\n" +
            "Ctrl+Alt+A   open a Prime Video window and pin it\n" +
            "Ctrl+Alt+Q   quit\n\n" +
            "EverQuest must run Windowed or Borderless.\n" +
            "Fullscreen-exclusive owns the display and nothing can sit on top of it.",
            "PipPin hotkeys", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void Notify(string title, string text)
    {
        try { tray.BalloonTipTitle = title; tray.BalloonTipText = text; tray.ShowBalloonTip(2000); } catch { }
    }

    private void Quit()
    {
        for (int i = 1; i <= 9; i++) { try { UnregisterHotKey(this.Handle, i); } catch { } }
        if (hover != null) hover.Stop();
        if (Alive() && pinned)
        {
            ReleaseCaption();
            SetWindowPos(target, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            alphaIdx = 0; ApplyAlpha();
        }
        tray.Visible = false;
        tray.Dispose();
        Application.Exit();
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing

[PipPin]::IconPath = Join-Path $PSScriptRoot 'PipPin.ico'
[PipPin]::MakeDpiAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run((New-Object PipPin))

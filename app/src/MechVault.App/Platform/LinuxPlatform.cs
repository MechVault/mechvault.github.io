using System.Runtime.InteropServices;
using System.Text;
using MechVault.Core;

namespace MechVault.App.Platform;

public sealed class LinuxPlatform : IGamePlatform
{
    readonly AppPaths _paths;
    readonly string? _tesseract;
    readonly bool _wayland;
    readonly bool _x11;
    static readonly object XLock = new();

    public LinuxPlatform(AppPaths paths)
    {
        _paths = paths;
        _wayland = string.Equals(Environment.GetEnvironmentVariable("XDG_SESSION_TYPE"), "wayland", StringComparison.OrdinalIgnoreCase)
                   || (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY")) && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")));
        _x11 = !_wayland && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY"));
        _tesseract = GamePlatform.Which("tesseract");
    }

    public bool CanRead => _x11 && _tesseract is not null;

    public string? Unavailable =>
        _wayland ? "Lettura automatica non disponibile su Wayland: inserisci i saldi a mano."
        : !_x11 ? "Lettura automatica non disponibile senza X11: inserisci i saldi a mano."
        : _tesseract is null ? "Per la lettura automatica installa Tesseract (pacchetto tesseract-ocr), poi riapri MechVault."
        : null;

    public string? Help => _wayland
        ? "Su Wayland nessun programma può guardare la finestra di un altro. Per la lettura automatica scegli una sessione «X11» (o «Xorg») all'accesso; altrimenti aggiorna i saldi a mano in Impostazioni."
        : _tesseract is null ? "Esempi: sudo apt install tesseract-ocr · sudo dnf install tesseract · sudo pacman -S tesseract tesseract-data-eng" : null;

    public bool CanRequestPermission => false;
    public void RequestPermission() { }

        public GameHandle? FindGame(string pattern)
    {
        var rx = GamePlatform.Pattern(pattern);
        if (rx is null) return null;
        var pids = new List<(int Pid, string Name)>();
        try
        {
            foreach (var d in Directory.EnumerateDirectories("/proc"))
            {
                if (!int.TryParse(Path.GetFileName(d), out var pid) || pid == Environment.ProcessId) continue;
                try
                {
                    var comm = File.ReadAllText(Path.Combine(d, "comm")).Trim();
                    var cmd = File.ReadAllText(Path.Combine(d, "cmdline")).Replace('\0', ' ');
                    if (cmd.Contains("MechVault", StringComparison.OrdinalIgnoreCase) && !cmd.Contains(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                    if (rx.IsMatch(comm) || rx.IsMatch(cmd)) pids.Add((pid, comm));
                }
                catch { }
            }
        }
        catch { }
        if (pids.Count == 0) return null;
        nint win = 0;
        if (_x11) lock (XLock) { win = X.FindWindow(pids.Select(p => p.Pid).ToHashSet(), rx); }
        var main = pids[0];
        return new GameHandle(main.Pid, main.Name, win);
    }

    public async Task<Dictionary<string, double>> ReadBalances(GameHandle g)
    {
        if (!CanRead || g.Window == 0) return new();
        Pixels? shot;
        lock (XLock) shot = X.Capture(g.Window);
        if (shot is null) return new();
        var dir = Path.Combine(Path.GetTempPath(), "mechvault-read-" + Environment.UserName);
        Directory.CreateDirectory(dir);
        try
        {
            var n = 0;
            return await BalanceReader.Read(shot, async p =>
            {
                var png = Path.Combine(dir, $"ocr{n++}.png");
                await File.WriteAllBytesAsync(png, Png.Encode(p));
                var (c, text) = await GamePlatform.Run(_tesseract!, new[] { png, "stdout", "--psm", "7", "-c", "tessedit_char_whitelist=0123456789.,KMkm" }, 10000);
                return c == 0 ? text : "";
            });
        }
        catch (Exception ex) { _paths.Log($"Lettura: {ex.Message}"); return new(); }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

        static class X
    {
        const string Lib = "libX11.so.6";
        [DllImport(Lib)] static extern int XInitThreads();
        [DllImport(Lib)] static extern nint XOpenDisplay(nint name);
        [DllImport(Lib)] static extern nint XDefaultRootWindow(nint d);
        [DllImport(Lib)] static extern nint XInternAtom(nint d, string name, bool onlyIfExists);
        [DllImport(Lib)] static extern int XGetWindowProperty(nint d, nint w, nint prop, nint offset, nint len, bool delete, nint reqType,
            out nint actualType, out int actualFormat, out nint nItems, out nint bytesAfter, out nint data);
        [DllImport(Lib)] static extern int XFree(nint p);
        [DllImport(Lib)] static extern nint XGetImage(nint d, nint w, int x, int y, uint width, uint height, nint planeMask, int format);
        [DllImport(Lib)] static extern int XGetWindowAttributes(nint d, nint w, out XWindowAttributes attr);
        [DllImport(Lib)] static extern nint XSetErrorHandler(ErrorHandler h);

        delegate int ErrorHandler(nint d, nint ev);
        delegate int DestroyImage(nint img);
        static readonly ErrorHandler IgnoreErrors = (_, _) => 0;

        [StructLayout(LayoutKind.Sequential)]
        struct XWindowAttributes
        {
            public int x, y, width, height, border_width, depth;
            public nint visual, root;
            public int c_class, bit_gravity, win_gravity, backing_store;
            public nint backing_planes, backing_pixel;
            public int save_under;
            public nint colormap;
            public int map_installed, map_state;
            public nint all_event_masks, your_event_mask, do_not_propagate_mask;
            public int override_redirect;
            public nint screen;
        }

        static nint _d;

        static nint D
        {
            get
            {
                if (_d == 0)
                {
                    XInitThreads();
                    XSetErrorHandler(IgnoreErrors);
                    _d = XOpenDisplay(0);
                }
                return _d;
            }
        }

        static nint[] Windows(nint d)
        {
            var root = XDefaultRootWindow(d);
            var atom = XInternAtom(d, "_NET_CLIENT_LIST", false);
            if (XGetWindowProperty(d, root, atom, 0, 4096, false, (nint)33 , out _, out var fmt, out var n, out _, out var data) != 0 || data == 0) return Array.Empty<nint>();
            try
            {
                var res = new nint[n];
                for (var i = 0; i < n; i++) res[i] = Marshal.ReadIntPtr(data, i * IntPtr.Size);
                return res;
            }
            finally { XFree(data); }
        }

        static long? Cardinal(nint d, nint w, string prop)
        {
            var atom = XInternAtom(d, prop, false);
            if (XGetWindowProperty(d, w, atom, 0, 1, false, (nint)6 , out _, out _, out var n, out _, out var data) != 0 || data == 0) return null;
            try { return n > 0 ? Marshal.ReadIntPtr(data).ToInt64() : null; }
            finally { XFree(data); }
        }

        static string Text(nint d, nint w, string prop)
        {
            var atom = XInternAtom(d, prop, false);
            if (XGetWindowProperty(d, w, atom, 0, 1024, false, 0 , out _, out _, out var n, out _, out var data) != 0 || data == 0) return "";
            try
            {
                var bytes = new byte[n];
                Marshal.Copy(data, bytes, 0, (int)n);
                return Encoding.UTF8.GetString(bytes).Replace('\0', ' ');
            }
            finally { XFree(data); }
        }

        public static nint FindWindow(HashSet<int> pids, System.Text.RegularExpressions.Regex rx)
        {
            var d = D;
            if (d == 0) return 0;
            nint best = 0; long bestArea = 0;
            foreach (var w in Windows(d))
            {
                var pid = Cardinal(d, w, "_NET_WM_PID");
                var match = pid is { } p && pids.Contains((int)p);
                if (!match) match = rx.IsMatch(Text(d, w, "WM_CLASS")) || rx.IsMatch(Text(d, w, "_NET_WM_NAME")) || rx.IsMatch(Text(d, w, "WM_NAME"));
                if (!match) continue;
                if (XGetWindowAttributes(d, w, out var a) == 0 || a.map_state != 2 ) continue;
                long area = (long)a.width * a.height;
                if (area > bestArea) { best = w; bestArea = area; }
            }
            return best;
        }

        public static Pixels? Capture(nint w)
        {
            var d = D;
            if (d == 0) return null;
            if (XGetWindowAttributes(d, w, out var a) == 0 || a.map_state != 2 || a.width < 200 || a.height < 150) return null;
            var img = XGetImage(d, w, 0, 0, (uint)a.width, (uint)a.height, (nint)(-1), 2 );
            if (img == 0) return null;
            try
            {
                int width = Marshal.ReadInt32(img, 0), height = Marshal.ReadInt32(img, 4);
                var data = Marshal.ReadIntPtr(img, 16);
                int bpl = Marshal.ReadInt32(img, 44), bpp = Marshal.ReadInt32(img, 48);
                if (bpp != 32 || data == 0) return null;
                var buf = new byte[width * height * 4];
                for (var y = 0; y < height; y++) Marshal.Copy(data + y * bpl, buf, y * width * 4, width * 4);
                for (var i = 3; i < buf.Length; i += 4) buf[i] = 255;
                return new Pixels(width, height, buf);
            }
            finally
            {
                var fn = Marshal.ReadIntPtr(img, 96);
                if (fn != 0) Marshal.GetDelegateForFunctionPointer<DestroyImage>(fn)(img);
            }
        }
    }
}

#if WINDOWS
using System.Runtime.InteropServices;
using MechVault.Core;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Security.Cryptography;

namespace MechVault.App.Platform;

public sealed class WindowsPlatform : IGamePlatform
{
    readonly AppPaths _paths;
    readonly OcrEngine? _ocr;

    public WindowsPlatform(AppPaths paths)
    {
        _paths = paths;
        try
        {
            _ocr = OcrEngine.TryCreateFromUserProfileLanguages();
            if (_ocr is null) paths.Log("OCR: nessuna lingua OCR installata");
        }
        catch (Exception ex) { paths.Log($"OCR init: {ex.Message}"); }
    }

    public bool CanRead => _ocr is not null;
    public string? Unavailable => _ocr is null ? "OCR di Windows non disponibile su questo PC." : null;
    public string? Help => null;
    public bool CanRequestPermission => false;
    public void RequestPermission() { }

    public GameHandle? FindGame(string pattern) => GamePlatform.FindByProcessName(pattern, true);

    public async Task<Dictionary<string, double>> ReadBalances(GameHandle g)
    {
        if (_ocr is null || g.Window == 0) return new();
        var shot = await Task.Run(() => Capture(g.Window));
        if (shot is null) return new();
        try { return await BalanceReader.Read(shot, Ocr); }
        catch (Exception ex) { _paths.Log($"Lettura: {ex.Message}"); return new(); }
    }

        public async Task<List<string>> Diagnose(GameHandle g, string dir)
    {
        var lines = new List<string>();
        var shot = Capture(g.Window);
        if (shot is null) { lines.Add("capture failed"); return lines; }
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "shot.png"), Png.Encode(shot));
        lines.Add($"shot {shot.W}x{shot.H}");
        foreach (var c in BalanceReader.Currencies)
        {
            var r = BalanceReader.FindAmountRect(shot, c.HueMin, c.HueMax);
            lines.Add($"{c.Key}: rect={r}");
            if (r.IsEmpty) continue;
            foreach (var sc in new[] { 2, 1, 3 })
            {
                var pb = BalanceReader.PrepForOcr(shot, r, sc);
                File.WriteAllBytes(Path.Combine(dir, $"{c.Key}-{sc}.png"), Png.Encode(pb));
                lines.Add($"  x{sc}: '{await Ocr(pb)}'");
            }
        }
        return lines;
    }

        public async Task<string> OcrFile(string path)
    {
        var f = await Windows.Storage.StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        using var stream = await f.OpenReadAsync();
        var dec = await BitmapDecoder.CreateAsync(stream);
        using var sb = await dec.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var res = await _ocr!.RecognizeAsync(sb);
        return res?.Text ?? "";
    }

    async Task<string> Ocr(Pixels p)
    {
        var buf = CryptographicBuffer.CreateFromByteArray(p.Bgra);
        using var sb = SoftwareBitmap.CreateCopyFromBuffer(buf, BitmapPixelFormat.Bgra8, p.W, p.H, BitmapAlphaMode.Premultiplied);
        var res = await _ocr!.RecognizeAsync(sb);
        return res?.Text ?? "";
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [DllImport("user32.dll")] static extern bool GetClientRect(nint h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(nint h, nint hdc, uint flags);
    [DllImport("user32.dll")] static extern bool IsIconic(nint h);
    [DllImport("user32.dll")] static extern nint GetDC(nint h);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint h, nint dc);
    [DllImport("gdi32.dll")] static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] static extern nint CreateDIBSection(nint dc, ref BITMAPINFOHEADER bmi, uint usage, out nint bits, nint section, uint offset);

        static Pixels? Capture(nint hwnd)
    {
        if (hwnd == 0 || IsIconic(hwnd)) return null;
        if (!GetClientRect(hwnd, out var r) || r.R < 200 || r.B < 150) return null;
        int w = r.R, h = r.B;
        var screen = GetDC(0);
        var mem = CreateCompatibleDC(screen);
        var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        var dib = CreateDIBSection(screen, ref bmi, 0, out var bits, 0, 0);
        try
        {
            if (dib == 0) return null;
            var old = SelectObject(mem, dib);
            var ok = PrintWindow(hwnd, mem, 3);
            SelectObject(mem, old);
            if (!ok) return null;
            var buf = new byte[w * h * 4];
            Marshal.Copy(bits, buf, 0, buf.Length);
            return new Pixels(w, h, buf);
        }
        finally
        {
            if (dib != 0) DeleteObject(dib);
            DeleteDC(mem);
            ReleaseDC(0, screen);
        }
    }
}
#endif

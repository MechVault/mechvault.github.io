
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class MechVaultReader
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

        public static Bitmap Capture(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || IsIconic(hwnd)) return null;
        RECT r;
        if (!GetClientRect(hwnd, out r) || r.R < 200 || r.B < 150) return null;
        var bmp = new Bitmap(r.R, r.B, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(hwnd, hdc, 3);
            g.ReleaseHdc(hdc);
            if (!ok) { bmp.Dispose(); return null; }
        }
        return bmp;
    }

    static float Hue(byte r, byte g, byte b, out float s, out float v)
    {
        float rf = r / 255f, gf = g / 255f, bf = b / 255f;
        float max = Math.Max(rf, Math.Max(gf, bf)), min = Math.Min(rf, Math.Min(gf, bf));
        v = max; s = max <= 0 ? 0 : (max - min) / max;
        if (max - min < 1e-4f) return 0;
        float h;
        if (max == rf) h = 60 * (((gf - bf) / (max - min)) % 6);
        else if (max == gf) h = 60 * (((bf - rf) / (max - min)) + 2);
        else h = 60 * (((rf - gf) / (max - min)) + 4);
        return h < 0 ? h + 360 : h;
    }

        public static Rectangle FindAmountRect(Bitmap src, float hueMin, float hueMax)
    {
        int W = src.Width, H = src.Height;
        int x0 = (int)(W * 0.45), y1 = Math.Max(20, (int)(H * 0.085));
        var area = new Rectangle(x0, 0, W - x0, y1);
        var d = src.LockBits(area, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = d.Stride, w = area.Width, h = area.Height;
        var buf = new byte[stride * h];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        src.UnlockBits(d);

        var col = new int[w];
        var mask = new bool[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * stride + x * 4;
                float s, v; float hu = Hue(buf[i + 2], buf[i + 1], buf[i], out s, out v);
                if (s > 0.55f && v > 0.55f && hu >= hueMin && hu <= hueMax) { col[x]++; mask[y * w + x] = true; }
            }

        int minCol = Math.Max(2, h / 12), gap = Math.Max(3, W / 400);
        var clusters = new List<int[]>();
        int start = -1, last = -1;
        for (int x = 0; x < w; x++)
        {
            if (col[x] >= minCol)
            {
                if (start < 0) start = x;
                else if (x - last > gap) { clusters.Add(new[] { start, last }); start = x; }
                last = x;
            }
        }
        if (start >= 0) clusters.Add(new[] { start, last });

        clusters.RemoveAll(c => c[1] - c[0] < Math.Max(4, W / 300));
        if (clusters.Count < 2) return Rectangle.Empty;

        int[] icon = null, plus = null;

        for (int a = 0; a < clusters.Count - 1 && icon == null; a++)
            for (int b = clusters.Count - 1; b > a; b--)
            {
                int dist = clusters[b][0] - clusters[a][1];
                if (dist > W * 0.03 && dist < W * 0.12) { icon = clusters[a]; plus = clusters[b]; break; }
            }
        if (icon == null) return Rectangle.Empty;

        int top = h, bot = -1;
        for (int y = 0; y < h; y++)
            for (int x = plus[0]; x <= plus[1]; x++)
                if (mask[y * w + x]) { if (y < top) top = y; if (y > bot) bot = y; break; }
        if (bot - top < 8) return Rectangle.Empty;

        int left = icon[1] + 3, right = plus[0] - 2;
        if (right - left < 10) return Rectangle.Empty;
        return new Rectangle(x0 + left, top, right - left, bot - top + 1);
    }

        public static Bitmap PrepForOcr(Bitmap src, Rectangle r, int scale)
    {
        int pad = 24;
        var outBmp = new Bitmap(r.Width * scale + pad * 2, r.Height * scale + pad * 2, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(outBmp))
        {
            g.Clear(Color.White);
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(src, new Rectangle(pad, pad, r.Width * scale, r.Height * scale), r, GraphicsUnit.Pixel);
        }
        var d = outBmp.LockBits(new Rectangle(0, 0, outBmp.Width, outBmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        var buf = new byte[d.Stride * outBmp.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        for (int y = 0; y < outBmp.Height; y++)
            for (int x = 0; x < outBmp.Width; x++)
            {
                int i = y * d.Stride + x * 4;
                bool inside = x >= pad && y >= pad && x < pad + r.Width * scale && y < pad + r.Height * scale;
                int mn = Math.Min(buf[i], Math.Min(buf[i + 1], buf[i + 2]));
                byte v = (byte)(inside && mn > 150 ? 0 : 255);
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255;
            }
        Marshal.Copy(buf, 0, d.Scan0, buf.Length);
        outBmp.UnlockBits(d);
        return outBmp;
    }
}

using System.IO.Compression;

namespace MechVault.Core;

public sealed class Pixels
{
    public int W { get; }
    public int H { get; }
    public int Stride { get; }
    public byte[] Bgra { get; }

    public Pixels(int w, int h, byte[] bgra, int stride = 0)
    {
        W = w; H = h; Stride = stride == 0 ? w * 4 : stride; Bgra = bgra;
    }

    public static Pixels White(int w, int h)
    {
        var b = new byte[w * h * 4];
        Array.Fill(b, (byte)255);
        return new Pixels(w, h, b);
    }
}

public readonly record struct Rect(int X, int Y, int W, int H)
{
    public bool IsEmpty => W <= 0 || H <= 0;
}

public static class BalanceReader
{
    public sealed record Currency(string Key, float HueMin, float HueMax);

    public static readonly Currency[] Currencies = { new("credits", 172f, 206f), new("acoins", 278f, 322f) };

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

        public static Rect FindAmountRect(Pixels src, float hueMin, float hueMax)
    {
        int W = src.W, H = src.H;
        int x0 = (int)(W * 0.45), y1 = Math.Min(H, Math.Max(20, (int)(H * 0.085)));
        int w = W - x0, h = y1;
        if (w <= 0 || h <= 0) return default;
        var col = new int[w];
        var mask = new bool[w * h];
        var buf = src.Bgra;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * src.Stride + (x0 + x) * 4;
                float hu = Hue(buf[i + 2], buf[i + 1], buf[i], out var s, out var v);
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
        if (clusters.Count < 2) return default;

        int[]? icon = null, plus = null;

        for (int a = 0; a < clusters.Count - 1 && icon is null; a++)
            for (int b = clusters.Count - 1; b > a; b--)
            {
                int dist = clusters[b][0] - clusters[a][1];
                if (dist > W * 0.03 && dist < W * 0.12) { icon = clusters[a]; plus = clusters[b]; break; }
            }
        if (icon is null || plus is null) return default;

        int top = h, bot = -1;
        for (int y = 0; y < h; y++)
            for (int x = plus[0]; x <= plus[1]; x++)
                if (mask[y * w + x]) { if (y < top) top = y; if (y > bot) bot = y; break; }
        if (bot - top < 8) return default;

        int left = icon[1] + 3, right = plus[0] - 2;
        if (right - left < 10) return default;
        return new Rect(x0 + left, top, right - left, bot - top + 1);
    }

        public static Pixels PrepForOcr(Pixels src, Rect r, int scale)
    {
        const int pad = 24;
        int ow = r.W * scale + pad * 2, oh = r.H * scale + pad * 2;
        var o = Pixels.White(ow, oh);
        for (int y = 0; y < r.H * scale; y++)
        {
            double sy = (y + 0.5) / scale - 0.5;
            int y0 = Math.Clamp((int)Math.Floor(sy), 0, r.H - 1), y1 = Math.Min(y0 + 1, r.H - 1);
            double fy = Math.Clamp(sy - y0, 0, 1);
            for (int x = 0; x < r.W * scale; x++)
            {
                double sx = (x + 0.5) / scale - 0.5;
                int xa = Math.Clamp((int)Math.Floor(sx), 0, r.W - 1), xb = Math.Min(xa + 1, r.W - 1);
                double fx = Math.Clamp(sx - xa, 0, 1);
                double mn = 255;
                for (int c = 0; c < 3; c++)
                {
                    double p00 = At(src, r.X + xa, r.Y + y0, c), p10 = At(src, r.X + xb, r.Y + y0, c);
                    double p01 = At(src, r.X + xa, r.Y + y1, c), p11 = At(src, r.X + xb, r.Y + y1, c);
                    var v = (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy;
                    if (v < mn) mn = v;
                }
                byte val = (byte)(mn > 150 ? 0 : 255);
                int i = (pad + y) * o.Stride + (pad + x) * 4;
                o.Bgra[i] = val; o.Bgra[i + 1] = val; o.Bgra[i + 2] = val; o.Bgra[i + 3] = 255;
            }
        }
        return o;
    }

    static byte At(Pixels p, int x, int y, int c) => p.Bgra[y * p.Stride + x * 4 + c];

        public static async Task<Dictionary<string, double>> Read(Pixels shot, Func<Pixels, Task<string>> ocr)
    {
        var res = new Dictionary<string, double>();
        foreach (var c in Currencies)
        {
            var r = FindAmountRect(shot, c.HueMin, c.HueMax);
            if (r.IsEmpty) continue;
            foreach (var sc in new[] { 2, 1, 3 })
            {
                var pb = PrepForOcr(shot, r, sc);
                var v = Num.ParseGameNumber(await ocr(pb));
                if (v is { } x && x < 1e9) { res[c.Key] = x; break; }
            }
        }
        return res;
    }
}

public static class Png
{
    static readonly uint[] Crc = MakeCrc();

    static uint[] MakeCrc()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[n] = c;
        }
        return t;
    }

    static void Chunk(Stream s, string type, byte[] data)
    {
        var len = new[] { (byte)(data.Length >> 24), (byte)(data.Length >> 16), (byte)(data.Length >> 8), (byte)data.Length };
        s.Write(len);
        var td = System.Text.Encoding.ASCII.GetBytes(type).Concat(data).ToArray();
        s.Write(td);
        var c = 0xFFFFFFFFu;
        foreach (var b in td) c = Crc[(c ^ b) & 0xFF] ^ (c >> 8);
        c ^= 0xFFFFFFFFu;
        s.Write(new[] { (byte)(c >> 24), (byte)(c >> 16), (byte)(c >> 8), (byte)c });
    }

    public static byte[] Encode(Pixels p)
    {
        using var ms = new MemoryStream();
        ms.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        var ihdr = new byte[13];
        ihdr[0] = (byte)(p.W >> 24); ihdr[1] = (byte)(p.W >> 16); ihdr[2] = (byte)(p.W >> 8); ihdr[3] = (byte)p.W;
        ihdr[4] = (byte)(p.H >> 24); ihdr[5] = (byte)(p.H >> 16); ihdr[6] = (byte)(p.H >> 8); ihdr[7] = (byte)p.H;
        ihdr[8] = 8; ihdr[9] = 6;
        Chunk(ms, "IHDR", ihdr);
        using (var raw = new MemoryStream())
        {
            using (var z = new ZLibStream(raw, CompressionLevel.Fastest, true))
            {
                var row = new byte[1 + p.W * 4];
                for (var y = 0; y < p.H; y++)
                {
                    row[0] = 0;
                    for (var x = 0; x < p.W; x++)
                    {
                        var i = y * p.Stride + x * 4;
                        row[1 + x * 4] = p.Bgra[i + 2]; row[2 + x * 4] = p.Bgra[i + 1]; row[3 + x * 4] = p.Bgra[i]; row[4 + x * 4] = p.Bgra[i + 3];
                    }
                    z.Write(row);
                }
            }
            Chunk(ms, "IDAT", raw.ToArray());
        }
        Chunk(ms, "IEND", Array.Empty<byte>());
        return ms.ToArray();
    }
}

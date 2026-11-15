using System.Globalization;
using System.Text.RegularExpressions;

namespace MechVault.Core;

public sealed class Env
{
    public Loc L { get; set; }
    public Func<DateTime> Now { get; set; }

    public Env(Loc? loc = null, Func<DateTime>? now = null)
    {
        L = loc ?? Loc.Italian();
        Now = now ?? (() => DateTime.Now);
    }

    public CultureInfo C => L.Culture;
    public string T(string k, params object?[] args) => L.T(k, args);

    public string Fmt(double n) => n.ToString("N0", C);

    public string Short(double n)
    {
        var a = Math.Abs(n);
        if (a >= 1e6) return (n / 1e6).ToString("0.##", C) + "M";
        if (a >= 1e4) return (n / 1e3).ToString("0.#", C) + "k";
        return Fmt(n);
    }

    public string Signed(double n) => n > 0 ? "+" + Fmt(n) : n < 0 ? "−" + Fmt(-n) : "0";
    public string CurName(string c) => c == "credits" ? T("crediti") : "A-coin";
    public static string CurColor(string c) => c == "credits" ? "#64D2FF" : "#DA8FFF";
    public static string CurColor2(string c) => c == "credits" ? "#0A84FF" : "#BF5AF2";
    public string Pct(double f) => (f * 100).ToString("0.##", C) + "%";

    public string Ago(string? t)
    {
        if (string.IsNullOrEmpty(t)) return T("mai");
        var d = Dates.Parse(t);
        if (d is null) return T("mai");
        var s = (Now() - d.Value).TotalSeconds;
        if (s < 45) return T("adesso");
        if (s < 3600) return T("{0} min fa", Num.ToInt(Math.Max(1.0, Math.Round(s / 60))));
        if (s < 86400) return T("{0} h fa", Num.ToInt(Math.Round(s / 3600)));
        return d.Value.ToString("d MMM HH:mm", C);
    }

    public string EtaDays(double days)
    {
        if (days < 0) return "—";
        if (days == 0) return T("ora");
        var dd = Num.ToInt(Math.Ceiling(days));
        return dd == 1 ? T("1 giorno") : T("{0} giorni", dd);
    }

        public string EtaFine(double days)
    {
        if (days < 0) return "—";
        if (days < 1 / 24.0) return T("meno di un'ora");
        if (days < 1)
        {
            var h = Num.ToInt(Math.Round(days * 24));
            return h == 1 ? T("1 ora") : T("{0} ore", h);
        }
        return EtaDays(days);
    }

    public string EtaDate(double days)
    {
        if (days < 0) return T("imposta il ritmo");
        if (days == 0) return T("oggi");
        return Now().AddDays(Math.Ceiling(days)).ToString("ddd d MMM", C);
    }
}

public static class Num
{
        public static int ToInt(double v) => (int)Math.Round(v, MidpointRounding.ToEven);

        public static double? ParseAmount(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = Regex.Replace(s.Trim().ToLowerInvariant(), @"\s", "");
        var mult = 1.0;
        if (s.EndsWith('k')) { mult = 1e3; s = s.TrimEnd('k'); }
        else if (s.EndsWith('m')) { mult = 1e6; s = s.TrimEnd('m'); }
        s = mult > 1 ? s.Replace(',', '.') : Regex.Replace(s, @"[\.,]", "");
        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
        if (v < 0) return null;
        return Math.Round(v * mult);
    }

        public static double? ParseGameNumber(string? t)
    {
        if (string.IsNullOrEmpty(t)) return null;
        t = Regex.Replace(Regex.Replace(t, "[Oo]", "0"), @"[^0-9\.,KkMm]", "");
        var m = Regex.Match(t, @"^(\d{1,4})(?:[\.,](\d{1,2}))?([KkMm])$");
        if (m.Success)
        {
            var num = double.Parse(m.Groups[1].Value + "." + (m.Groups[2].Success && m.Groups[2].Value != "" ? m.Groups[2].Value : "0"), CultureInfo.InvariantCulture);
            var mult = m.Groups[3].Value is "K" or "k" ? 1e3 : 1e6;
            return Math.Round(num * mult);
        }
        if (Regex.IsMatch(t, @"^\d{1,3}([\.,]\d{3}){1,2}$")) return double.Parse(Regex.Replace(t, @"[\.,]", ""), CultureInfo.InvariantCulture);
        if (Regex.IsMatch(t, @"^\d{1,7}$")) return double.Parse(t, CultureInfo.InvariantCulture);
        return null;
    }

        public static double? ParsePct(string? t)
    {
        if (string.IsNullOrWhiteSpace(t)) return null;
        if (!double.TryParse(t.Trim().TrimEnd('%').Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
        if (v <= 0 || v > 100) return null;
        return v / 100;
    }

        public static int? ParseIntIn(string? t, int min, int max)
    {
        if (!int.TryParse((t ?? "").Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var x)) return null;
        return x < min || x > max ? null : x;
    }
}

public static class Dates
{
        public static DateTime? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dto))
        {
            if (!Regex.IsMatch(s, @"(Z|[+-]\d\d:?\d\d)\s*$")) return dto.DateTime;
            return dto.LocalDateTime;
        }
        if (DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d;
        return null;
    }

    public static DateTime ParseOr(string? s, DateTime fallback) => Parse(s) ?? fallback;

        public static string Iso(DateTime d)
    {
        if (d.Kind == DateTimeKind.Utc) d = d.ToLocalTime();
        return new DateTimeOffset(DateTime.SpecifyKind(d, DateTimeKind.Unspecified), TimeZoneInfo.Local.GetUtcOffset(d)).ToString("o", CultureInfo.InvariantCulture);
    }
}

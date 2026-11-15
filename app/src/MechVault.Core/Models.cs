using System.Text.Json;
using System.Text.Json.Serialization;

namespace MechVault.Core;

public sealed class BalanceEvent
{
    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("cur")] public string Cur { get; set; } = "credits";
    [JsonPropertyName("delta")] public double Delta { get; set; }
    [JsonPropertyName("bal")] public double Bal { get; set; }
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("note")] public string? Note { get; set; } = "";
    [JsonPropertyName("src")] public string? Src { get; set; } = "";
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    [JsonIgnore] public DateTime Time => Dates.ParseOr(T, DateTime.MinValue);
}

public sealed class Goal
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("currency")] public string Currency { get; set; } = "credits";
    [JsonPropertyName("cost")] public double Cost { get; set; }
    [JsonPropertyName("done")] public bool Done { get; set; }
    [JsonPropertyName("doneAt")] public string? DoneAt { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class Violation
{
    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("currency")] public string Currency { get; set; } = "credits";
    [JsonPropertyName("amount")] public double Amount { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; } = "";
    [JsonPropertyName("streakLost")] public int StreakLost { get; set; }
    [JsonPropertyName("prevClean")] public string? PrevClean { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class Purchase
{
    [JsonPropertyName("goalId")] public string GoalId { get; set; } = "";
    [JsonPropertyName("currency")] public string Currency { get; set; } = "credits";
    [JsonPropertyName("amount")] public double Amount { get; set; }
    [JsonPropertyName("until")] public string Until { get; set; } = "";
}

public sealed class AccountData
{
    [JsonPropertyName("version")] public int Version { get; set; } = 3;
    [JsonPropertyName("accountName")] public string AccountName { get; set; } = "Principale";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("credits")] public double Credits { get; set; }
    [JsonPropertyName("acoins")] public double Acoins { get; set; }
    [JsonPropertyName("initCredits")] public bool InitCredits { get; set; }
    [JsonPropertyName("initAcoins")] public bool InitAcoins { get; set; }
    [JsonPropertyName("events")] public List<BalanceEvent> Events { get; set; } = new();
    [JsonPropertyName("goals")] public List<Goal> Goals { get; set; } = new();
    [JsonPropertyName("rateCredits")] public double RateCredits { get; set; }
    [JsonPropertyName("rateAcoins")] public double RateAcoins { get; set; }
    [JsonPropertyName("missionCredits")] public double MissionCredits { get; set; } = 2000;
    [JsonPropertyName("missionAcoins")] public double MissionAcoins { get; set; }
    [JsonPropertyName("violations")] public List<Violation> Violations { get; set; } = new();
    [JsonPropertyName("purchase")] public Purchase? Purchase { get; set; }
    [JsonPropertyName("cleanSince")] public string CleanSince { get; set; } = "";
    [JsonPropertyName("bestStreak")] public int BestStreak { get; set; }
    [JsonPropertyName("processPattern")] public string ProcessPattern { get; set; } = "mech.?arena";
    [JsonPropertyName("autoRead")] public bool AutoRead { get; set; } = true;
    [JsonPropertyName("showBanner")] public bool ShowBanner { get; set; } = true;
    [JsonPropertyName("autostart")] public bool Autostart { get; set; } = true;
    [JsonPropertyName("firstRun")] public bool FirstRun { get; set; } = true;
    [JsonPropertyName("lastReadAt")] public string? LastReadAt { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    public double Balance(string cur) => cur == "credits" ? Credits : Acoins;
    public void SetBalance(string cur, double v) { if (cur == "credits") Credits = v; else Acoins = v; }
    public bool IsInit(string cur) => cur == "credits" ? InitCredits : InitAcoins;
    public void SetInit(string cur, bool v) { if (cur == "credits") InitCredits = v; else InitAcoins = v; }
    public double MissionBudget(string cur) => cur == "credits" ? MissionCredits : MissionAcoins;
    public double ManualRate(string cur) => cur == "credits" ? RateCredits : RateAcoins;

    public static AccountData Default(DateTime now)
    {
        var iso = Dates.Iso(now);
        return new AccountData { CreatedAt = iso, CleanSince = iso };
    }

    public void AddEvent(DateTime now, string cur, double delta, double bal, string kind, string note, string src)
    {
        Events.Add(new BalanceEvent { T = Dates.Iso(now), Cur = cur, Delta = delta, Bal = bal, Kind = kind, Note = note, Src = src });
        if (Events.Count > 3000) Events.RemoveRange(0, Events.Count - 3000);
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new TolerantListConverterFactory() },
    };

        public static void WriteAtomic(string path, string text)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text, new System.Text.UTF8Encoding(false));
        File.Move(tmp, path, true);
    }

        public static string ReadText(string path)
    {
        for (var i = 0; ; i++)
        {
            try { return File.ReadAllText(path, System.Text.Encoding.UTF8); }
            catch (IOException) when (i < 7) { Thread.Sleep(250); }
        }
    }
}

sealed class TolerantListConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type t) => t.IsGenericType && t.GetGenericTypeDefinition() == typeof(List<>);

    public override JsonConverter CreateConverter(Type t, JsonSerializerOptions o) =>
        (JsonConverter)Activator.CreateInstance(typeof(Conv<>).MakeGenericType(t.GetGenericArguments()[0]))!;

    sealed class Conv<T> : JsonConverter<List<T>>
    {
        public override bool HandleNull => true;

        public override List<T> Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
        {
            var list = new List<T>();
            if (r.TokenType == JsonTokenType.Null) return list;
            if (r.TokenType == JsonTokenType.StartArray)
            {
                while (r.Read() && r.TokenType != JsonTokenType.EndArray)
                {
                    if (r.TokenType == JsonTokenType.Null) continue;
                    var v = JsonSerializer.Deserialize<T>(ref r, o);
                    if (v is not null) list.Add(v);
                }
                return list;
            }
            var one = JsonSerializer.Deserialize<T>(ref r, o);
            if (one is not null) list.Add(one);
            return list;
        }

        public override void Write(Utf8JsonWriter w, List<T> v, JsonSerializerOptions o)
        {
            w.WriteStartArray();
            foreach (var x in v) JsonSerializer.Serialize(w, x, o);
            w.WriteEndArray();
        }
    }
}

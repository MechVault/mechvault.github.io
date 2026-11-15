using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MechVault.Core;

public sealed class AppPaths
{
    public string Here { get; }
    public string Data { get; }
    public string CalcDir => Path.Combine(Here, "calc");
    public string LangDir => Path.Combine(Here, "lang");
    public string Accounts => Path.Combine(Data, "accounts");
    public string Active => Path.Combine(Data, "active.txt");
    public string LangFile => Path.Combine(Data, "lang.txt");
    public string Ui => Path.Combine(Data, "ui.json");
    public string Overlay => Path.Combine(Data, "overlay.json");
    public string Costs => Path.Combine(Data, "costi.json");
    public string WikiCache => Path.Combine(Data, "wiki-mechs.json");
    public string MechCustom => Path.Combine(Data, "mech-miei.json");
    public string LogFile => Path.Combine(Data, "errori.log");
    public string Legacy => Path.Combine(Data, "data.json");
    public string OldIndex => Path.Combine(Data, "accounts.json");

    public AppPaths(string here, string data)
    {
        Here = here; Data = data;
        Directory.CreateDirectory(Data);
    }

        public static AppPaths Default()
    {
        var here = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var env = Environment.GetEnvironmentVariable("MECHVAULT_DATA");
        string data;
        if (!string.IsNullOrEmpty(env)) data = env;
        else if (OperatingSystem.IsWindows()) data = Path.Combine(here, "dati");
        else if (OperatingSystem.IsMacOS())
            data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "MechVault");
        else
        {
            var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            if (string.IsNullOrEmpty(xdg)) xdg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
            data = Path.Combine(xdg, "MechVault");
        }
        return new AppPaths(here, data);
    }

    public void Log(string m)
    {
        for (var i = 0; i < 3; i++)
        {
            try { File.AppendAllText(LogFile, $"{DateTime.Now:s}  {m}{Environment.NewLine}", new System.Text.UTF8Encoding(false)); return; }
            catch { Thread.Sleep(150); }
        }
    }
}

public sealed class UiPrefs
{
    readonly string _file;
    public UiPrefs(string file) { _file = file; }

    JsonObject Read()
    {
        try { if (File.Exists(_file) && JsonNode.Parse(Json.ReadText(_file)) is JsonObject o) return o; } catch { }
        return new JsonObject();
    }

    public bool GetBool(string k, bool def)
    {
        var o = Read();
        return o[k] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : def;
    }

    public string? GetString(string k)
    {
        var o = Read();
        return o[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    }

    public void Set(string k, JsonNode? v)
    {
        var o = Read();
        o[k] = v;
        Json.WriteAtomic(_file, o.ToJsonString(Json.Options));
    }
}

public sealed class OverlayPrefs
{
    public string Mode { get; set; } = "full";
    public double? X { get; set; }
    public double? Y { get; set; }
    public bool Compat { get; set; }

    public static OverlayPrefs Load(string file)
    {
        var o = new OverlayPrefs();
        try
        {
            if (File.Exists(file) && JsonNode.Parse(Json.ReadText(file)) is JsonObject j)
            {
                var m = j["mode"]?.ToString();
                if (m is "full" or "small" or "mini") o.Mode = m;
                if (j["x"] is JsonValue x && x.TryGetValue<double>(out var xv) && j["y"] is JsonValue y && y.TryGetValue<double>(out var yv)) { o.X = xv; o.Y = yv; }
                o.Compat = j["compat"] is JsonValue c && c.TryGetValue<bool>(out var cb) && cb;
            }
        }
        catch { }
        return o;
    }

    public void Save(string file)
    {
        var j = new JsonObject { ["mode"] = Mode, ["x"] = X, ["y"] = Y, ["compat"] = Compat };
        try { Json.WriteAtomic(file, j.ToJsonString(Json.Options)); } catch { }
    }

    public string NextMode() => Mode switch { "full" => "small", "small" => "mini", _ => "full" };
}

public sealed record AccountInfo(string Id, string Name);

public sealed class AccountStore
{
    readonly AppPaths _p;
    readonly Env _env;
    public string? ActiveId { get; private set; }
    public AccountData Data { get; private set; } = new();
    public string? DataFile => ActiveId is null ? null : Path.Combine(_p.Accounts, ActiveId + ".json");

    public AccountStore(AppPaths p, Env env) { _p = p; _env = env; }

    static readonly string[] Obsolete = { "history", "tolCredits", "tolAcoins" };

    public AccountData Load(string path)
    {
        if (File.Exists(path))
        {
            try
            {
                var d = JsonSerializer.Deserialize<AccountData>(Json.ReadText(path), Json.Options) ?? AccountData.Default(_env.Now());
                if (d.Extra is not null) foreach (var k in Obsolete) d.Extra.Remove(k);
                if (string.IsNullOrEmpty(d.CleanSince)) d.CleanSince = string.IsNullOrEmpty(d.CreatedAt) ? Dates.Iso(_env.Now()) : d.CreatedAt;
                if (string.IsNullOrEmpty(d.CreatedAt)) d.CreatedAt = d.CleanSince;
                if (d.Events.Count == 0)
                {
                    foreach (var c in new[] { "credits", "acoins" })
                        if (d.IsInit(c)) d.AddEvent(_env.Now(), c, 0, d.Balance(c), "init", "saldo iniziale", "manuale");
                }
                d.Version = 3;
                return d;
            }
            catch (Exception ex)
            {
                _p.Log($"Account illeggibile ({path}): {ex.Message}");
                try { File.Copy(path, $"{path}.rotto-{DateTime.Now:yyyyMMddHHmmss}"); } catch { }
            }
        }
        return AccountData.Default(_env.Now());
    }

    public void Save()
    {
        if (DataFile is null) return;
        try { Json.WriteAtomic(DataFile, JsonSerializer.Serialize(Data, Json.Options)); }
        catch (Exception ex) { _p.Log($"Salvataggio fallito: {ex.Message}"); }
    }

    void SetActive(string id)
    {
        ActiveId = id;
        try { File.WriteAllText(_p.Active, id); } catch (Exception ex) { _p.Log($"active.txt: {ex.Message}"); }
    }

    public List<AccountInfo> List()
    {
        var list = new List<AccountInfo>();
        if (!Directory.Exists(_p.Accounts)) return list;

        var rows = new List<(DateTime When, DateTime File, AccountInfo Info)>();
        foreach (var f in new DirectoryInfo(_p.Accounts).GetFiles("*.json"))
        {
            var id = Path.GetFileNameWithoutExtension(f.Name);
            string? name = null, created = null;
            if (id == ActiveId) { name = Data.AccountName; created = Data.CreatedAt; }
            else try { var j = JsonNode.Parse(Json.ReadText(f.FullName)); name = j?["accountName"]?.ToString(); created = j?["createdAt"]?.ToString(); } catch { }
            if (string.IsNullOrEmpty(name)) name = _env.T("Account del {0}", f.CreationTime.ToString("d MMM", _env.C));
            rows.Add((Dates.Parse(created) ?? f.CreationTime, f.CreationTime, new AccountInfo(id, name)));
        }
        list.AddRange(rows.OrderBy(r => r.When).ThenBy(r => r.File).ThenBy(r => r.Info.Id, StringComparer.Ordinal).Select(r => r.Info));
        return list;
    }

        public void Init(bool importOld = true)
    {
        Directory.CreateDirectory(_p.Accounts);
        if (importOld && OperatingSystem.IsWindows() && Directory.GetFiles(_p.Accounts, "*.json").Length == 0)
        {
            var old = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MechVault");
            if (Directory.Exists(old))
            {
                try
                {
                    var oa = Path.Combine(old, "accounts");
                    if (Directory.Exists(oa)) foreach (var f in Directory.GetFiles(oa, "*.json")) File.Copy(f, Path.Combine(_p.Accounts, Path.GetFileName(f)), false);
                    foreach (var f in new[] { "accounts.json", "active.txt", "data.json" })
                    {
                        var src = Path.Combine(old, f);
                        if (File.Exists(src) && !File.Exists(Path.Combine(_p.Data, f))) File.Copy(src, Path.Combine(_p.Data, f));
                    }
                    _p.Log($"Importati i dati da {old}");
                }
                catch (Exception ex) { _p.Log($"Import vecchi dati: {ex.Message}"); }
            }
        }
        if (File.Exists(_p.Legacy)) File.Move(_p.Legacy, Path.Combine(_p.Accounts, Goals.NewId() + ".json"), true);
        if (File.Exists(_p.OldIndex))
        {
            try
            {
                var idx = JsonNode.Parse(Json.ReadText(_p.OldIndex));
                if (idx?["list"] is JsonArray arr)
                    foreach (var a in arr)
                    {
                        var path = Path.Combine(_p.Accounts, a?["id"]?.ToString() + ".json");
                        if (!File.Exists(path)) continue;
                        var d = Load(path);
                        if (string.IsNullOrEmpty(d.AccountName) || d.AccountName == "Principale") d.AccountName = a?["name"]?.ToString() ?? d.AccountName;
                        Json.WriteAtomic(path, JsonSerializer.Serialize(d, Json.Options));
                    }
                var act = idx?["active"]?.ToString();
                if (!string.IsNullOrEmpty(act) && File.Exists(Path.Combine(_p.Accounts, act + ".json"))) File.WriteAllText(_p.Active, act);
                File.Move(_p.OldIndex, _p.OldIndex + ".old", true);
            }
            catch (Exception ex) { _p.Log($"Migrazione accounts.json: {ex.Message}"); }
        }
        var files = new DirectoryInfo(_p.Accounts).GetFiles("*.json");
        if (files.Length == 0)
        {
            SetActive(Goals.NewId());
            Data = AccountData.Default(_env.Now());
            Save();
            return;
        }
        string? active = null;
        try { if (File.Exists(_p.Active)) active = File.ReadAllText(_p.Active).Trim(); } catch { }
        if (string.IsNullOrEmpty(active) || !File.Exists(Path.Combine(_p.Accounts, active + ".json")))
            active = Path.GetFileNameWithoutExtension(files.OrderByDescending(f => f.LastWriteTime).First().Name);
        SetActive(active);
        Data = Load(DataFile!);
    }

    public bool Switch(string id)
    {
        if (!File.Exists(Path.Combine(_p.Accounts, id + ".json"))) return false;
        Save();
        SetActive(id);
        Data = Load(DataFile!);
        return true;
    }

        public void Create(string name)
    {
        var prev = Data;
        Save();
        var d = AccountData.Default(_env.Now());
        d.AccountName = name; d.FirstRun = false;
        if (prev is not null)
        {
            d.ProcessPattern = prev.ProcessPattern; d.AutoRead = prev.AutoRead; d.ShowBanner = prev.ShowBanner;
            d.Autostart = prev.Autostart; d.MissionCredits = prev.MissionCredits; d.MissionAcoins = prev.MissionAcoins;
        }
        SetActive(Goals.NewId());
        Data = d;
        Save();
    }

    public void Rename(string name) { Data.AccountName = name; Save(); }

        public bool RemoveActive()
    {
        var accs = List();
        if (accs.Count <= 1 || DataFile is null) return false;
        var old = DataFile;
        var next = accs.First(a => a.Id != ActiveId).Id;
        SetActive(next);
        Data = Load(DataFile!);
        try { Trash.Move(old); } catch (Exception ex) { _p.Log($"Eliminazione account: {ex.Message}"); }
        return true;
    }
}

public static class Trash
{
    public static void Move(string path)
    {
        if (OperatingSystem.IsWindows()) { WinRecycle(path); return; }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string dir;
        if (OperatingSystem.IsMacOS()) dir = Path.Combine(home, ".Trash");
        else
        {
            var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            if (string.IsNullOrEmpty(xdg)) xdg = Path.Combine(home, ".local", "share");
            dir = Path.Combine(xdg, "Trash", "files");
            var info = Path.Combine(xdg, "Trash", "info");
            Directory.CreateDirectory(info);
            File.WriteAllText(Path.Combine(info, Path.GetFileName(path) + ".trashinfo"),
                $"[Trash Info]\nPath={path}\nDeletionDate={DateTime.Now:yyyy-MM-ddTHH:mm:ss}\n");
        }
        Directory.CreateDirectory(dir);
        var dest = Path.Combine(dir, Path.GetFileName(path));
        if (File.Exists(dest)) dest = Path.Combine(dir, $"{Path.GetFileNameWithoutExtension(path)}-{DateTime.Now:yyyyMMddHHmmss}{Path.GetExtension(path)}");
        File.Move(path, dest);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd; public uint wFunc; public string pFrom; public string? pTo; public ushort fFlags;
        public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    static void WinRecycle(string path)
    {
        var op = new SHFILEOPSTRUCT { wFunc = 3, pFrom = path + "\0\0", fFlags = 0x40 | 0x10 | 0x4 | 0x400 };
        var r = SHFileOperation(ref op);
        if (r != 0) throw new IOException($"SHFileOperation {r}");
    }
}

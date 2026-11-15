# MechVault

Free, fan-made Windows resource planner for Mech Arena: goal manager, automatic balance tracking (screen reading only), upgrade calculator, Crate Rush analysis and mech sheet.

**Website and download: https://mechvault.github.io**

- Website: the `docs/` folder, served by GitHub Pages from `main` / `/docs`.
- Download: `docs/MechVault.zip`. Rebuild it with `powershell -ExecutionPolicy Bypass -File build.ps1`, which also writes the SHA-256 into the site.
- Languages: `lang/<code>.json` holds `[italian, translation]` pairs. Copy `en.json`, translate the second string of each pair, and the language appears in Settings.

The goal manager and the upgrade calculator are written for MechVault. Upgrade costs for 1-6 stars ship in `calc/wiki-costs.json`, taken from the [Mech Arena: Robot Showdown Wiki](https://mech-arena-robot-showdown.fandom.com/wiki/Weapons) (Mechs and Weapons pages) under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/); that file keeps the same license. `calc/cost-fixes.json` holds in-game corrections applied on top of the wiki data (epic weapon star-ups 810 A-coins, epic mech star-ups 1,875 A-coins, rare mech 4★ level 7 25,000 credits, legendary mech 5★ level 7 125,000 credits). Your corrections go to `dati/costi.json`, and Export/Import lets pilots share the table.

**Not affiliated with, endorsed or sponsored by Plarium Global Ltd.** Mech Arena and related names and trademarks belong to their respective owners.

Mech stats (max HP, speed, energy, ability, viability notes) for 47 mechs ship in `calc/mech-stats.json`, taken from the same wiki's mech pages under CC BY-SA 3.0.

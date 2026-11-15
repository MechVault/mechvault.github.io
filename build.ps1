$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$docs = Join-Path $root 'docs'
$zip  = Join-Path $docs 'MechVault.zip'
$tmp  = Join-Path $env:TEMP ('mvbuild_' + [guid]::NewGuid().ToString('N'))

$parse = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'MechVault.ps1'), [ref]$null, [ref]$parse)
if ($parse) { throw "MechVault.ps1 has syntax errors: $($parse[0].Message)" }

$app = Join-Path $tmp 'MechVault'
New-Item -ItemType Directory -Path (Join-Path $app 'lang'), (Join-Path $app 'calc') -Force | Out-Null
Copy-Item (Join-Path $root 'MechVault.ps1'), (Join-Path $root 'MechVaultReader.cs'), (Join-Path $root 'MechVault Start.cmd'), (Join-Path $root 'README.md') $app
Copy-Item (Join-Path $root 'lang\*.json') (Join-Path $app 'lang')
Copy-Item (Join-Path $root 'calc\*.json') (Join-Path $app 'calc')
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $app -DestinationPath $zip
Remove-Item $tmp -Recurse -Force

$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$ver = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'MechVault.ps1')), "\`$script:AppVersion = '([\d.]+)'").Groups[1].Value
if (-not $ver) { throw 'AppVersion not found in MechVault.ps1' }
$vj = [ordered]@{ version = $ver; sha256 = $sha; date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); url = 'https://mechvault.github.io/MechVault.zip' }
$vjPath = Join-Path $docs 'version.json'
if (Test-Path $vjPath) { $prev = [IO.File]::ReadAllText($vjPath) | ConvertFrom-Json; if ($prev.platforms) { $vj.platforms = $prev.platforms } }
[IO.File]::WriteAllText((Join-Path $docs 'version.json'), ($vj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

"Version        $ver"
"MechVault.zip  $([math]::Round((Get-Item $zip).Length / 1KB)) KB"
"SHA-256        $sha"
"VirusTotal     https://www.virustotal.com/gui/file/$sha"

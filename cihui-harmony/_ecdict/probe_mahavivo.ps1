$ErrorActionPreference = 'Stop'
$base = 'https://ghproxy.net/https://api.github.com/repos/mahavivo/english-wordlists/git/trees/master?recursive=1'
try {
  $r = Invoke-WebRequest -Uri $base -TimeoutSec 60 -UseBasicParsing -Headers @{ 'User-Agent' = 'cihui' }
  $j = $r.Content | ConvertFrom-Json
  $j.tree | Where-Object { $_.path -match '\.(txt|md|csv)$' } | ForEach-Object { Write-Output $_.path }
} catch {
  Write-Output ("FAIL " + $_.Exception.Message)
}

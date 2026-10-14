$urls = @(
  'https://data.jsdelivr.com/v1/packages/gh/mahavivo/english-wordlists',
  'https://ghproxy.net/https://raw.githubusercontent.com/mahavivo/english-wordlists/master/README.md'
)
foreach ($u in $urls) {
  try {
    $r = Invoke-WebRequest -Uri $u -TimeoutSec 40 -UseBasicParsing -Headers @{ 'User-Agent' = 'cihui' }
    Write-Output ("OK " + $u)
    $out = Join-Path 'F:\PORJECT\cihui-harmony\_ecdict' ('probe_' + [Math]::Abs($u.GetHashCode()) + '.txt')
    [System.IO.File]::WriteAllText($out, $r.Content, [System.Text.Encoding]::UTF8)
    Write-Output $r.Content.Substring(0, [Math]::Min(2500, $r.Content.Length))
  } catch {
    Write-Output ("FAIL " + $u + "  " + $_.Exception.Message)
  }
}

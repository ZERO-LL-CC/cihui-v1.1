$urls = @(
  'https://data.jsdelivr.com/v1/packages/gh/kajweb/dict',
  'https://ghproxy.net/https://raw.githubusercontent.com/kajweb/dict/master/README.md'
)
foreach ($u in $urls) {
  try {
    $r = Invoke-WebRequest -Uri $u -TimeoutSec 40 -UseBasicParsing -Headers @{ 'User-Agent' = 'cihui' }
    Write-Output ("OK " + $u + " len=" + $r.Content.Length)
    Write-Output $r.Content.Substring(0, [Math]::Min(3000, $r.Content.Length))
    Write-Output "----"
  } catch {
    Write-Output ("FAIL " + $u + "  " + $_.Exception.Message)
  }
}

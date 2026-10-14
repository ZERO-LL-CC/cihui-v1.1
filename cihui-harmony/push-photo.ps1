param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$ImagePath
)
# push-photo.ps1 <host image path>
# Push a phone photo (already copied to PC) into the Mate60 emulator gallery
# (DeveloperAlbum). It then appears in the system photo picker used by Cihui.
# Filename must be ASCII; non-ASCII names are auto-renamed.
$ErrorActionPreference = 'Stop'
$hdc = 'E:\AAALSRJ\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

if (-not (Test-Path $ImagePath)) { Write-Error "image not found: $ImagePath"; exit 1 }
$full = (Resolve-Path $ImagePath).Path
$name = [System.IO.Path]::GetFileName($full)
if ($name -match '[^\x00-\x7F]') {
  $ext = [System.IO.Path]::GetExtension($name)
  if (-not $ext) { $ext = '.jpg' }
  $stamp = Get-Date -Format 'yyyyMMddHHmmss'
  $name = "photo_$stamp$ext"
  $dest = Join-Path $env:TEMP $name
  Copy-Item $full $dest -Force
  $full = $dest
  Write-Host "renamed to ASCII: $name"
}
$remote = "/mnt/data/100/media_fuse/Photo/$name"
& $hdc file send "$full" "$remote"
if ($LASTEXITCODE -ne 0) { Write-Error "hdc send failed (is the emulator running?)"; exit 1 }
Start-Sleep 2
& $hdc shell "ls -l /mnt/data/100/media_fuse/Photo/DeveloperAlbum/$name"
Write-Host ""
Write-Host "Pushed to emulator gallery: $name"
Write-Host "In Cihui: camera import -> album pick -> select this photo -> done."

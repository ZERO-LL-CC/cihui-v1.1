$py = 'C:\Users\zx\AppData\Local\Doubao\User Data\sandbox_runtime\bases\c98c5042338ed152c6f10ecd8591889f\python\python.exe'
& $py 'F:\PORJECT\cihui-harmony\_ecdict\generate_books.py'
Get-ChildItem 'F:\PORJECT\cihui-harmony\Cihui\entry\src\main\resources\rawfile\cloudbooks' | ForEach-Object { Write-Output ($_.Name + ' ' + $_.Length) }

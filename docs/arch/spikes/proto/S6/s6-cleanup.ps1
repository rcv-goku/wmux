# wmux spike S6: remove every system change the spike makes and verify.
#  - %LOCALAPPDATA%\Microsoft\WindowsApps\wmuxspikefwd*   (files, hard links, renamed leftovers)
#  - HKCU\Software\wmuxspikefwd*                           (InstallDir value, RegGetValueW probe)
#  - HKCU\...\App Paths\wmuxspikefwd*.exe                  (App Paths probe)
# Processes named wmuxspikefwd* (orphans from kill tests) are stopped first.
. (Join-Path $PSScriptRoot 's6-common.ps1')
$ErrorActionPreference = 'Continue'
Get-Process -Name 'wmuxspikefwd*' -ErrorAction SilentlyContinue | ForEach-Object { "stopping orphan $($_.ProcessName) $($_.Id)"; Stop-Process -Id $_.Id -Force }
Start-Sleep -Milliseconds 300
$removed = @()
foreach ($f in Get-SpikeWindowsAppsFiles) {
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed += $f.Name }
    catch { "FAILED to remove $($f.FullName): $_" }
}
Get-ChildItem 'HKCU:\Software' | Where-Object { $_.PSChildName -like 'wmuxspikefwd*' } | ForEach-Object {
    Remove-Item -Path $_.PSPath -Recurse -Force; $removed += "HKCU\Software\$($_.PSChildName)"
}
Get-ChildItem $S6.AppPathsKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'wmuxspikefwd*' } | ForEach-Object {
    Remove-Item -Path $_.PSPath -Recurse -Force; $removed += "App Paths\$($_.PSChildName)"
}
"removed: " + ($removed -join ', ')
$left = Get-SpikeWindowsAppsFiles
"WindowsApps wmuxspikefwd* remaining: $($left.Count)"
"HKCU\Software\wmuxspikefwd* keys remaining: $(@(Get-ChildItem 'HKCU:\Software' | Where-Object { $_.PSChildName -like 'wmuxspikefwd*' }).Count)"
"App Paths wmuxspikefwd* remaining: $(@(Get-ChildItem $S6.AppPathsKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'wmuxspikefwd*' }).Count)"

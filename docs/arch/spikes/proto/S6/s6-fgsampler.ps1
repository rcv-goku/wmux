# wmux spike S6: foreground sampler. Logs every foreground-window change
# (GetForegroundWindow + GetWindowThreadProcessId every 100 ms) until $StopFile exists.
param([Parameter(Mandatory)][string]$Log, [Parameter(Mandatory)][string]$StopFile)
Add-Type -Namespace S6 -Name Fg -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
'@
$last = ''
"start`t$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $Log
while (-not (Test-Path -LiteralPath $StopFile)) {
    $h = [S6.Fg]::GetForegroundWindow()
    $fpid = [uint32]0
    [void][S6.Fg]::GetWindowThreadProcessId($h, [ref]$fpid)
    $key = "$h/$fpid"
    if ($key -ne $last) {
        $name = (Get-Process -Id $fpid -ErrorAction SilentlyContinue).ProcessName
        "$((Get-Date).ToString('o'))`t$h`t$fpid`t$name" | Add-Content -LiteralPath $Log
        $last = $key
    }
    Start-Sleep -Milliseconds 100
}
"stop`t$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $Log

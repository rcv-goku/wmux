# wmux spike S6: which RegGetValueW flag combinations read REG_SZ / REG_EXPAND_SZ values
# (InstallDir lookup in the forwarder, user PATH check in install-cli). Uses a temporary
# HKCU\Software\wmuxspikefwd-regtest key that is deleted at the end.
$ErrorActionPreference = 'Stop'
Add-Type -Namespace S6R -Name Reg -MemberDefinition @'
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RegGetValueW(UIntPtr hkey, string subKey, string value, uint flags, out uint type, System.Text.StringBuilder data, ref uint cb);
'@
$HKCU = [UIntPtr]::new([uint64]::Parse('FFFFFFFF80000001', 'HexNumber'))
$key = 'HKCU:\Software\wmuxspikefwd-regtest'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name Sz -Value 'C:\Wmux Spike' -PropertyType String | Out-Null
New-ItemProperty -Path $key -Name Exp -Value '%LOCALAPPDATA%\Programs\wmux' -PropertyType ExpandString | Out-Null
$flags = [ordered]@{
    'RRF_RT_REG_SZ'                             = 0x2
    'RRF_RT_REG_EXPAND_SZ'                      = 0x4
    'RRF_RT_REG_EXPAND_SZ|RRF_NOEXPAND'         = 0x10000004
    'RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ'        = 0x6
    'RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ|NOEXPAND' = 0x10000006
}
$out = [ordered]@{}
try {
    foreach ($target in @(@('Software\wmuxspikefwd-regtest', 'Sz'), @('Software\wmuxspikefwd-regtest', 'Exp'), @('Environment', 'Path'))) {
        foreach ($fn in $flags.Keys) {
            $sb = [Text.StringBuilder]::new(32768); $cb = [uint32](32768 * 2); $type = [uint32]0
            $rc = [S6R.Reg]::RegGetValueW($HKCU, $target[0], $target[1], [uint32]$flags[$fn], [ref]$type, $sb, [ref]$cb)
            $val = if ($rc -eq 0) { $s = $sb.ToString(); if ($s.Length -gt 60) { $s.Substring(0, 60) + '...' } else { $s } } else { '' }
            $out["HKCU\$($target[0])\$($target[1]) :: $fn"] = "rc=$rc type=$type $val".Replace($env:USERPROFILE, '%USERPROFILE%')
        }
    }
} finally { Remove-Item -Path $key -Recurse -Force }
$out['cleanup: regtest key exists'] = Test-Path $key
$out | ConvertTo-Json

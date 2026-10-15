# Run the S7 measurement matrix (sequential; each run is a fresh hidden process).
# Usage: pwsh matrix.ps1 -Out <scratch dir> [-Name matrix]   (expects <Out>\s7proto.exe from build.ps1)
param([Parameter(Mandatory = $true)][string]$Out, [string]$Name = 'matrix', [int]$Steps = 60)
$exe = Join-Path $Out 's7proto.exe'
$res = Join-Path $Out $Name
$W = "--webview=1 --steps=$Steps"
$runs = @(
    "A1-hwndrt-immediate-sync|--mode=hwndrt --present=1 --sync=1 $W --tests=all",
    "A1n-hwndrt-immediate-sync-nocap|--mode=hwndrt --present=1 --sync=1 --nocap=1 $W --tests=resize,drag",
    "A2-hwndrt-vsync-sync|--mode=hwndrt --present=0 --sync=1 $W --tests=resize,drag,timing",
    "A3-hwndrt-immediate-async|--mode=hwndrt --present=1 --sync=0 $W --tests=resize,drag,timing",
    "A4-hwndrt-immediate-sync-defer|--mode=hwndrt --present=1 --sync=1 --defer=1 $W --tests=resize,drag",
    "A5-hwndrt-noclip|--mode=hwndrt --present=1 --sync=1 --clip=0 $W --tests=resize,drag",
    "A6-hwndrt-software|--mode=hwndrt --present=1 --sync=1 --swhwndrt=1 $W --tests=capture,timing,devloss,resize",
    "A7-hwndrt-retain|--mode=hwndrt --present=2 --sync=1 $W --tests=resize,timing",
    "A8-hwndrt-noglwait-nocap|--mode=hwndrt --present=1 --sync=1 --glwait=0 --nocap=1 $W --tests=resize,drag",
    "A9-hwndrt-skipclean|--mode=hwndrt --present=1 --sync=1 --skipclean=1 $W --tests=resize,drag,timing",
    "A9n-hwndrt-skipclean-nocap|--mode=hwndrt --present=1 --sync=1 --skipclean=1 --nocap=1 $W --tests=resize,drag",
    "B1-flip-sync|--mode=flip --sync=1 $W --tests=all",
    "B2-flip-scalingnone|--mode=flip --sync=1 --flipnone=1 $W --tests=resize,drag",
    "B3-flip-vsync|--mode=flip --sync=1 --flipvsync=1 $W --tests=timing,resize",
    "C1-dcrt-async|--mode=dcrt --sync=0 $W --tests=all",
    "C1n-dcrt-async-nocap|--mode=dcrt --sync=0 --nocap=1 $W --tests=resize,drag",
    "C2-dcrt-sync|--mode=dcrt --sync=1 $W --tests=resize,drag,timing",
    "C3-dcrt-software|--mode=dcrt --sync=0 --swdcrt=1 $W --tests=timing,resize,devloss",
    "L1-hwndrt-layered|--mode=hwndrt --present=1 --sync=1 --layered=1 $W --tests=capture,resize,drag",
    "L2-dcrt-layered|--mode=dcrt --sync=0 --layered=1 $W --tests=capture,resize",
    "D96-hwndrt-real96dpi|--mode=hwndrt --present=1 --sync=1 --pos=1000,3500 $W --tests=capture,resize,drag,timing,dpi",
    "W1-flip-wgc-live|--mode=flip --sync=1 --webview=0 --steps=20 --tests=wdrag",
    "W2-hwndrt-wgc-live|--mode=hwndrt --sync=1 --webview=1 --steps=20 --tests=wdrag",
    "ABI-broken|--mode=hwndrt --tests=abi_broken"
)
& (Join-Path $PSScriptRoot 'run-s7.ps1') -Exe $exe -Out $res -Run $runs -TimeoutSec 300

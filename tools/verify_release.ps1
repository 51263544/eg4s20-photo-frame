<#
verify_release.ps1 - pre-submission self check for the P2..P8 release.

Checks, in order:
  1. the frozen bitstream and firmware hex exist and match the MD5 recorded
     in doc/hw/P8_RELEASE.md (fail = the board would be flashed with
     something other than what was verified),
  2. the two copies of m0_code.hex (m0_p2\ and prj\p2_sd_display\) agree,
  3. optionally, if a card is inserted, the /CHARS layout by replaying the
     firmware scan offline (tools\check_card.py).

Usage (this box has Windows PowerShell 5.1, there is no pwsh.exe):
  powershell -ExecutionPolicy Bypass -File tools\verify_release.ps1
  powershell -ExecutionPolicy Bypass -File tools\verify_release.ps1 -Card F
#>
param(
    [string]$Card = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot           # ...\project0
$prj  = Join-Path $root 'prj\p2_sd_display'

$expectBit = '1F4BFAC58E9612AFD868D0C73FFD55E2'
$expectHex = 'FAD1C79C10CD1F09AC063E44E8578D27'

$fail = 0

function Check([string]$what, [string]$path, [string]$expect) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("  MISSING  {0}  ({1})" -f $what, $path) -ForegroundColor Red
        $script:fail++
        return
    }
    $got = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash
    if ($got -eq $expect) {
        Write-Host ("  OK       {0}  {1}" -f $what, $got) -ForegroundColor Green
    } else {
        Write-Host ("  MISMATCH {0}`n           got    {1}`n           expect {2}" -f $what, $got, $expect) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host '== frozen artifacts =='
Check 'bitstream' (Join-Path $prj 'p2_sd_display.bit') $expectBit
$hexA = Join-Path $root 'm0_p2\m0_code.hex'
$hexB = Join-Path $prj  'm0_code.hex'
Check 'firmware hex (m0_p2)' $hexA $expectHex
Check 'firmware hex (prj)'   $hexB $expectHex

Write-Host '== card layout =='
if ($Card) {
    $dev = $Card.TrimEnd(':')
    $py = 'D:\python\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { $py = 'python' }
    & $py (Join-Path $PSScriptRoot 'check_card.py') $dev
    if ($LASTEXITCODE -ne 0) { $fail++ }
} else {
    Write-Host '  skipped (pass -Card F to validate an inserted card)'
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'VERDICT: PASS - artifacts match the frozen release' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("VERDICT: FAIL - {0} problem(s) above" -f $fail) -ForegroundColor Red
    exit 1
}

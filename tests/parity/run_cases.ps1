# Run every case of migration\cases.txt with a driver exe and store the results in a directory.
#   capture golden (ONLY from the C++ baseline):
#     tests\parity\run_cases.ps1 -Exe build\cpp\cpp_driver.exe -OutDir migration\golden
#   run the Nim driver into a scratch dir and compare with the golden dumps:
#     tests\parity\run_cases.ps1 -Exe build\nim_driver.exe -OutDir C:\Temp\opencode\nim_out -CompareWith migration\golden [-Tol 0] [-Filter svg_]
# Per case it writes <name>.out (stdout line) .err .rc .argb .ppm.
# With -CompareWith: stdout hash equal => PASS; otherwise the .argb files are compared per channel
# (premultiplied ARGB8888): reports differing pixel count, max channel delta, first differing pixel.
# -Tol N: a case also passes when every channel differs by at most N (default 0 = bit exact).
# Always run from the project root. Exit code 0 = all pass (or capture mode), 1 = some fail.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Cases = 'migration\cases.txt',
  [string]$CompareWith = '',
  [int]$Tol = 0,
  [string]$Filter = '',
  [int]$TimeoutSec = 120
)
[Environment]::CurrentDirectory = (Get-Location).Path
$exeFull = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFull = (Resolve-Path $OutDir).Path

Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class ArgbDiff {
  // returns "same" or "N px differ, max delta D, first at (x,y) golden=AARRGGBB actual=AARRGGBB" ; maxDelta via out
  public static string Compare(string golden, string actual, int width, out int maxDelta, out long ndiff) {
    maxDelta = 0; ndiff = 0;
    if (!File.Exists(actual)) return "no actual dump";
    byte[] a = File.ReadAllBytes(golden), b = File.ReadAllBytes(actual);
    if (a.Length != b.Length) { maxDelta = 255; ndiff = -1; return "size golden=" + a.Length + " actual=" + b.Length; }
    string first = null;
    for (int i = 0; i + 3 < a.Length; i += 4) {
      bool d = false;
      for (int k = 0; k < 4; k++) { int dl = Math.Abs(a[i + k] - b[i + k]); if (dl > 0) { d = true; if (dl > maxDelta) maxDelta = dl; } }
      if (d) {
        ndiff++;
        if (first == null) {
          int p = i / 4; uint ga = BitConverter.ToUInt32(a, i), ba = BitConverter.ToUInt32(b, i);
          first = "(" + (p % width) + "," + (p / width) + ") golden=" + ga.ToString("x8") + " actual=" + ba.ToString("x8");
        }
      }
    }
    return ndiff == 0 ? "same" : ndiff + " px differ, max delta " + maxDelta + ", first at " + first;
  }
}
'@

$pass = 0; $fail = 0
foreach ($raw in Get-Content $Cases) {
  $l = $raw.Trim(); if ($l -eq '' -or $l.StartsWith('#')) { continue }
  $parts = $l -split '\|'
  $name = $parts[0].Trim(); $a = $parts[1].Trim()
  if ($Filter -and $name -notlike "*$Filter*") { continue }
  $base = Join-Path $outFull $name
  Remove-Item "$base.*" -ErrorAction SilentlyContinue
  $line = "`"$exeFull`" $a --dump `"$base`" > `"$base.out`" 2> `"$base.err`""
  $p = Start-Process cmd.exe -ArgumentList '/c', "`"$line`"" -NoNewWindow -PassThru
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { cmd /c "taskkill /T /F /PID $($p.Id) >NUL 2>&1"; Set-Content "$base.rc" 'TIMEOUT'; $rc = 'TIMEOUT' }
  else { $p.WaitForExit(); $rc = "$($p.ExitCode)"; Set-Content "$base.rc" $rc }
  if (-not $CompareWith) { Write-Host "[run] $name rc=$rc : $((Get-Content "$base.out" -ErrorAction SilentlyContinue) -join ' ')"; $pass++; continue }
  $gold = (Resolve-Path $CompareWith).Path
  $grc = (Get-Content (Join-Path $gold "$name.rc")).Trim()
  $gout = ((Get-Content (Join-Path $gold "$name.out")) -join "`n").Trim()
  $aout = ((Get-Content "$base.out" -ErrorAction SilentlyContinue) -join "`n").Trim()
  if ($rc -ne $grc) { $fail++; $e = ((Get-Content "$base.err" -ErrorAction SilentlyContinue) | Select-Object -First 1); Write-Host "[FAIL] $name : rc golden=$grc actual=$rc $e"; continue }
  if ($gout -ceq $aout) { $pass++; continue }
  $w = [int](([regex]::Match($gout, 'size=(\d+)x')).Groups[1].Value)
  $md = 0; $nd = [long]0
  $msg = [ArgbDiff]::Compare((Join-Path $gold "$name.argb"), "$base.argb", $w, [ref]$md, [ref]$nd)
  if ($msg -eq 'same') { $pass++; continue }
  if ($Tol -gt 0 -and $nd -ge 0 -and $md -le $Tol) { $pass++; Write-Host "[tol ] $name : $msg"; continue }
  $fail++; Write-Host "[FAIL] $name : $msg"
}
Write-Host "[run_cases] PASS=$pass FAIL=$fail exe=$exeFull"
if ($fail -gt 0) { exit 1 } else { exit 0 }

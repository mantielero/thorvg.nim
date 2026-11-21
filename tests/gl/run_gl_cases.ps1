# GL parity: runs the Nim GL driver on every case of migration\cases.txt and compares with
# migration\golden_gl (captured ONLY from build\cppgl\cpp_gl_driver.exe, the original C++ GL engine).
# Same logic as tests\parity\run_cases.ps1 (stdout hash first, then the .argb dumps per channel), plus
# a table per group (name prefix: shapes svg png pngrot jpg gif webp text) and a list of failures.
#   powershell -File tests\gl\run_gl_cases.ps1 -Mode release            # build\nim_gl_driver_release.exe
#   powershell -File tests\gl\run_gl_cases.ps1 -Mode debug -Filter svg_
#   powershell -File tests\gl\run_gl_cases.ps1 -Exe build\cppgl\cpp_gl_driver.exe -OutDir C:\Temp\opencode\x  (any driver)
# Build the drivers:
#   nimc.ps1 -Src tests\gl\nim_gl_driver.nim -Mode release -Strict -Out build\nim_gl_driver_release.exe -Extra '--nimcache:build\nimcache\glrel'
#   nimc.ps1 -Src tests\gl\nim_gl_driver.nim -Mode debug   -Strict -Out build\nim_gl_driver_debug.exe   -Extra '--nimcache:build\nimcache\gldbg'
# -Tol N: a case also passes when every channel differs by at most N (default 0 = bit exact, the parity target).
# Output per case in -OutDir: <name>.out .err .rc .argb .rgba .ppm; failures are listed in <OutDir>\_failures.txt.
# Run from the project root. Exit code 0 = all pass, 1 = some fail. One GL context per case process.
param(
  [string]$Mode = 'release',
  [string]$Exe = '',
  [string]$OutDir = '',
  [string]$Cases = 'migration\cases.txt',
  [string]$CompareWith = 'migration\golden_gl',
  [int]$Tol = 0,
  [string]$Filter = '',
  [int]$TimeoutSec = 120
)
[Environment]::CurrentDirectory = (Get-Location).Path
if (-not $Exe) { $Exe = "build\nim_gl_driver_$Mode.exe" }
if (-not $OutDir) { $OutDir = "C:\Temp\opencode\gl_out_$Mode" }
$exeFull = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFull = (Resolve-Path $OutDir).Path
$gold = (Resolve-Path $CompareWith).Path

Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class ArgbDiff {
  // "same" or "N px differ, max delta D, first at (x,y) golden=AARRGGBB actual=AARRGGBB"
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

$stat = @{}   # group -> @(pass, total)
$failures = New-Object System.Collections.ArrayList
function Add-Stat($g, $ok) {
  if (-not $stat.ContainsKey($g)) { $stat[$g] = @(0, 0) }
  $stat[$g][1]++
  if ($ok) { $stat[$g][0]++ }
}
foreach ($raw in Get-Content $Cases) {
  $l = $raw.Trim(); if ($l -eq '' -or $l.StartsWith('#')) { continue }
  $parts = $l -split '\|'
  $name = $parts[0].Trim(); $a = $parts[1].Trim()
  if ($Filter -and $name -notlike "*$Filter*") { continue }
  $group = ($name -split '_')[0]
  $base = Join-Path $outFull $name
  Remove-Item "$base.*" -ErrorAction SilentlyContinue
  $line = "`"$exeFull`" $a --dump `"$base`" > `"$base.out`" 2> `"$base.err`""
  $p = Start-Process cmd.exe -ArgumentList '/c', "`"$line`"" -NoNewWindow -PassThru
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { cmd /c "taskkill /T /F /PID $($p.Id) >NUL 2>&1"; Set-Content "$base.rc" 'TIMEOUT'; $rc = 'TIMEOUT' }
  else { $p.WaitForExit(); $rc = "$($p.ExitCode)"; Set-Content "$base.rc" $rc }
  $grc = (Get-Content (Join-Path $gold "$name.rc")).Trim()
  $gout = ((Get-Content (Join-Path $gold "$name.out")) -join "`n").Trim()
  $aout = ((Get-Content "$base.out" -ErrorAction SilentlyContinue) -join "`n").Trim()
  if ($rc -ne $grc) {
    $e = ((Get-Content "$base.err" -ErrorAction SilentlyContinue) | Select-Object -First 1)
    $m = "[FAIL] $name : rc golden=$grc actual=$rc $e"; Write-Host $m; [void]$failures.Add($m); Add-Stat $group $false; continue
  }
  if ($gout -ceq $aout) { Add-Stat $group $true; continue }
  $w = [int](([regex]::Match($gout, 'size=(\d+)x')).Groups[1].Value)
  $md = 0; $nd = [long]0
  $msg = [ArgbDiff]::Compare((Join-Path $gold "$name.argb"), "$base.argb", $w, [ref]$md, [ref]$nd)
  if ($msg -eq 'same') { Add-Stat $group $true; continue }
  if ($Tol -gt 0 -and $nd -ge 0 -and $md -le $Tol) { Add-Stat $group $true; Write-Host "[tol ] $name : $msg"; continue }
  $m = "[FAIL] $name : $msg"; Write-Host $m; [void]$failures.Add($m); Add-Stat $group $false
}
$tp = 0; $tt = 0
Write-Host "group      pass/total"
foreach ($g in ($stat.Keys | Sort-Object)) {
  $s = $stat[$g]; $tp += $s[0]; $tt += $s[1]
  Write-Host ("{0,-10} {1}/{2}" -f $g, $s[0], $s[1])
}
Set-Content (Join-Path $outFull '_failures.txt') $failures
Write-Host "[run_gl_cases] PASS=$tp FAIL=$($tt - $tp) exe=$exeFull"
if ($tt -gt $tp) { exit 1 } else { exit 0 }

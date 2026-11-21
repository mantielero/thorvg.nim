# Bit-exact parity of the Nim VP8 (lossy WebP) decoder against the original ThorVG C++ decoder.
#
# Usage (after dot-sourcing env.ps1, from the project root):
#   tests\parity\webp_lossy_compare.ps1 [-Mutations 6] [-Seed 1] [-Filter <substring>]
#
# 1. builds build\cpp\cpp_webp_dump_lossy.exe (C++ original) and build\nim_webp_dump_lossy.exe (Nim)
#    when missing or older than their sources,
# 2. decodes every file of tests\data\webp\lossy with both (BGRA and RGBA output) and compares the dumps,
# 3. creates -Mutations corrupted/truncated variants of each small file (seeded) and compares those
#    too: both decoders must either fail together or produce identical pixels.
# Exit code 0 only when everything matches.
param(
  [int]$Mutations = 6,
  [int]$Seed = 1,
  [string]$Filter = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root
[Environment]::CurrentDirectory = $root
$scripts = 'C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts'
$T = 'upstream/thorvg'
$W = "$T/src/modules/webp/static"
$cppExe = 'build\cpp\cpp_webp_dump_lossy.exe'
$nimExe = 'build\nim_webp_dump_lossy.exe'
$work = 'build\webp_lossy'
New-Item -ItemType Directory -Force 'build\cpp', $work | Out-Null

function Build-Cpp {
  $names = 'dec/alpha', 'dec/buffer', 'dec/frame', 'dec/io', 'dec/quant', 'dec/tree', 'dec/vp8', 'dec/vp8l',
    'dec/webp', 'dsp/alpha_processing', 'dsp/cpu', 'dsp/dec', 'dsp/dec_clip_tables', 'dsp/filters',
    'dsp/lossless', 'dsp/yuv', 'utils/bit_reader', 'utils/color_cache', 'utils/huffman'
  $srcs = $names | ForEach-Object { "$W/$_.cpp" }
  $flags = @('-std=c++14', '-O2', '-DNDEBUG', '-ffp-contract=off', '-fno-math-errno', '-Wno-unknown-pragmas', '-w',
    '-DTVG_STATIC', '-DNOMINMAX', '-Ibuild/cpp/include', "-I$T/inc", "-I$T/src/common", "-I$T/src/renderer", "-I$W")
  & g++ @flags @srcs 'tests/parity/cpp_webp_dump_lossy.cpp' -o $cppExe
  if ($LASTEXITCODE -ne 0) { throw 'C++ dump build failed' }
}

if (-not (Test-Path $cppExe) -or (Get-Item $cppExe).LastWriteTime -lt (Get-Item 'tests\parity\cpp_webp_dump_lossy.cpp').LastWriteTime) {
  Write-Host '[build] C++ dump'
  Build-Cpp
}
Write-Host '[build] Nim dump (release)'
& "$scripts\nimc.ps1" -Src 'tests\parity\nim_webp_dump_lossy.nim' -Mode release -Strict -Out $nimExe | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Nim dump build failed' }

function Compare-One([string]$file, [string]$tag, [string]$fmt) {
  $a = "$work\$tag.$fmt.cpp.bin"
  $b = "$work\$tag.$fmt.nim.bin"
  & $cppExe $file $a $fmt
  & $nimExe $file $b $fmt
  $ha = (Get-FileHash $a).Hash
  $hb = (Get-FileHash $b).Hash
  $dims = [BitConverter]::ToInt32([IO.File]::ReadAllBytes($a), 0)
  return @{ ok = ($ha -eq $hb); decoded = ($dims -gt 0) }
}

function Find-Payload([byte[]]$b) {
  $pos = 12
  while ($pos + 8 -le $b.Length) {
    $sz = [BitConverter]::ToUInt32($b, $pos + 4)
    if ([Text.Encoding]::ASCII.GetString($b, $pos, 4) -eq 'VP8 ') { return $pos + 8 }
    $pos += 8 + $sz + ($sz -band 1)
  }
  return -1
}

$files = Get-ChildItem 'tests\data\webp\lossy\*.webp' | Where-Object { $_.Name -like "*$Filter*" }
$total = 0; $bad = 0; $decodedCount = 0; $failedBoth = 0
foreach ($f in $files) {
  foreach ($fmt in 'bgra', 'rgba') {
    $r = Compare-One $f.FullName "$($f.BaseName)" $fmt
    $total++
    if (-not $r.ok) { $bad++; Write-Host "MISMATCH $($f.Name) [$fmt]" -ForegroundColor Red }
    if ($r.decoded) { $decodedCount++ }
  }
}
Write-Host "files: $($files.Count) compared $total dumps, mismatches $bad"

$rnd = New-Object System.Random($Seed)
$mtotal = 0; $mbad = 0; $mdecoded = 0
foreach ($f in $files) {
  if ($f.Length -gt 20000) { continue }
  $orig = [IO.File]::ReadAllBytes($f.FullName)
  $pay = Find-Payload $orig
  for ($k = 0; $k -lt $Mutations; $k++) {
    $b = [byte[]]$orig.Clone()
    $kind = $k % 3
    if ($kind -eq 0) {          # flip a few bytes after the frame header
      $n = 1 + $rnd.Next(8)
      for ($i = 0; $i -lt $n; $i++) { $b[$pay + 10 + $rnd.Next($b.Length - $pay - 10)] = $rnd.Next(256) }
    } elseif ($kind -eq 1) {    # truncate
      $cut = $pay + 10 + $rnd.Next($b.Length - $pay - 10)
      $b = [byte[]]($b[0..($cut - 1)])
    } else {                    # damage the frame tag / first partition bytes
      $b[$pay + [int]($rnd.Next(3))] = $rnd.Next(256)
      $b[$pay + 10 + $rnd.Next(12)] = $rnd.Next(256)
    }
    $mf = "$work\mut_$($f.BaseName)_$k.webp"
    [IO.File]::WriteAllBytes($mf, $b)
    $r = Compare-One $mf "mut_$($f.BaseName)_$k" 'bgra'
    $mtotal++
    if ($r.decoded) { $mdecoded++ }
    if (-not $r.ok) { $mbad++; Write-Host "MISMATCH $mf" -ForegroundColor Red }
  }
}
Write-Host "mutations: $mtotal compared, $mdecoded decoded by both, mismatches $mbad"
if ($bad -ne 0 -or $mbad -ne 0) { exit 1 }
Write-Host 'PARITY OK' -ForegroundColor Green

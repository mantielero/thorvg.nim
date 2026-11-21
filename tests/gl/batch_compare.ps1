# G2c differential oracle: C++ tvgGlSolidBatch.cpp + tvgGlStencilCoverBatch.cpp vs the Nim port
# (solid_batch/stencil_batch), bit exact: stage arrays after every op + the render tasks of the pass.
# Usage (project root, after dot-sourcing env.ps1):  .\tests\gl\batch_compare.ps1 [-Mode release|debug] [-Seed N]
# Needs the objects of tests/gl/Makefile.gl (build\cppgl\obj); builds the shim + Nim dump in build\bdump.
param([ValidateSet('debug', 'release')][string]$Mode = 'release', [string]$Seed = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $root
$out = Join-Path $root 'build\bdump'
New-Item -ItemType Directory -Force $out | Out-Null
$tvg = 'upstream/thorvg'; $src = "$tvg/src"; $obj = 'build/cppgl/obj/upstream/thorvg/src'
if (-not (Test-Path "$obj/common/tvgMath.o")) { $obj = 'build/cppgl/obj/src' }

$inc = @("build/cppgl/include", "$tvg/inc", "$src/common", "$src/renderer", "$src/renderer/cpu_engine",
         "$src/renderer/gpu_engine", "$src/renderer/gpu_engine/gl", "$src/modules") | ForEach-Object { "-I$_" }
$cxxflags = @('-std=c++14', '-O2', '-DNDEBUG', '-ffp-contract=off', '-fno-math-errno', '-Wno-unknown-pragmas', '-w',
              '-DTVG_STATIC', '-DNOMINMAX', '-DTHORVG_GL_TARGET_GL=1') + $inc

# 1. C++ shim: the ORIGINAL batch / render pass / geometry sources compiled from upstream. The GL stage
#    buffer and render task methods are re-implemented in the shim without GL, so no context is needed.
$objs = @('common/tvgMath.o', 'common/tvgArray.o', 'common/tvgStr.o', 'common/tvgCompressor.o') | ForEach-Object { "$obj/$_" }
$gl = "$src/renderer/gpu_engine/gl"
& g++ @cxxflags tests/gl/batch_dump.cpp "$gl/tvgGlSolidBatch.cpp" "$gl/tvgGlStencilCoverBatch.cpp" "$gl/tvgGlRenderPass.cpp" "$gl/tvgGlGeometry.cpp" "$gl/tvgGlTessellator.cpp" `
  "$src/renderer/gpu_engine/tvgGpuCommon.cpp" "$src/renderer/tvgRender.cpp" @objs -o "$out\dump_cpp.exe"
if ($LASTEXITCODE -ne 0) { Write-Error 'C++ shim build failed'; exit 1 }

# 2. Nim dump
$flags = @(if ($Mode -eq 'release') { '-d:release' } else { '--checks:on'; '--stacktrace:on' })
& nim c --hints:off --mm:orc --threads:on --styleCheck:error @flags "--nimcache:$out\nc_$Mode" "-o:$out\dump_nim.exe" tests/gl/batch_dump.nim
if ($LASTEXITCODE -ne 0) { Write-Error 'Nim dump build failed'; exit 1 }

# 3. cases + both runs + diff
if ($Seed) { & "$out\dump_nim.exe" gen "$out\cases.txt" $Seed } else { & "$out\dump_nim.exe" gen "$out\cases.txt" }
& "$out\dump_cpp.exe" "$out\cases.txt" "$out\out_cpp.txt"
if ($LASTEXITCODE -ne 0) { Write-Error 'C++ run failed'; exit 1 }
& "$out\dump_nim.exe" run "$out\cases.txt" "$out\out_nim.txt"
if ($LASTEXITCODE -ne 0) { Write-Error 'Nim run failed'; exit 1 }

$a = [IO.File]::ReadAllLines("$out\out_cpp.txt")
$b = [IO.File]::ReadAllLines("$out\out_nim.txt")
$cases = [IO.File]::ReadAllLines("$out\cases.txt")
$bad = 0
$n = [Math]::Max($a.Length, $b.Length)
for ($i = 0; $i -lt $n; $i++) {
  if ($i -ge $a.Length -or $i -ge $b.Length -or $a[$i] -ne $b[$i]) {
    $bad++
    if ($bad -le 3) {
      Write-Host "MISMATCH line $($i + 1): $($cases[$i])"
      $x = if ($i -lt $a.Length) { $a[$i] } else { '' }; $y = if ($i -lt $b.Length) { $b[$i] } else { '' }
      $px = $x -split ' \| '; $py = $y -split ' \| '
      for ($k = 0; $k -lt [Math]::Max($px.Length, $py.Length); $k++) {
        if ($px[$k] -ne $py[$k]) { Write-Host "  field ${k}:"; Write-Host "    cpp: $($px[$k])"; Write-Host "    nim: $($py[$k])" }
      }
    }
  }
}
$ops = $cases | ForEach-Object { ($_ -split ' ')[0] } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "cases: $($a.Length) ($($ops -join ' '))  mismatches: $bad"
if ($bad -ne 0) { exit 1 }
Write-Host 'BATCH ORACLE OK (bit exact)'

# Appends the WebP parity cases (group webp_) to migration\cases.txt; idempotent (removes the
# old webp_ lines first). Run from the project root. Format: name | webp:<file> W H
#   - every file of tests\data\webp (real, gen\, lossy\, alph\) is shown at its native size
#     (a direct blit of the decoded bitmap) when it is small, else scaled to fit;
#   - a few files are additionally shown scaled/enlarged (resampling of the premultiplied bitmap).
# The native size is read from the VP8X / VP8 / VP8L header; files that are not valid fall back
# to 33x17 (they produce an empty canvas or "cannot load" with the same exit code in both drivers).
$root = (Get-Location).Path
$lines = New-Object System.Collections.Generic.List[string]
foreach ($l in Get-Content migration\cases.txt) {
  if ($l -match '^webp_' -or $l -match '^# --- WebP') { continue }
  $lines.Add($l)
}
function Get-WebpSize([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -ge 30 -and $b[0] -eq 82 -and $b[1] -eq 73 -and $b[8] -eq 87) {
    $tag = [Text.Encoding]::ASCII.GetString($b, 12, 4)
    if ($tag -eq 'VP8X') { return @((1 + ($b[24] + 256 * $b[25] + 65536 * $b[26])), (1 + ($b[27] + 256 * $b[28] + 65536 * $b[29]))) }
    if ($tag -eq 'VP8 ' -and $b.Length -ge 30) { return @((($b[26] + 256 * $b[27]) -band 0x3fff), (($b[28] + 256 * $b[29]) -band 0x3fff)) }
    if ($tag -eq 'VP8L' -and $b.Length -ge 25) {
      $v = $b[21] + 256 * $b[22] + 65536 * $b[23] + 16777216 * [long]$b[24]
      return @((1 + ($v -band 0x3fff)), (1 + (($v -shr 14) -band 0x3fff)))
    }
  }
  return @(33, 17)
}
$lines.Add('# --- WebP (tests\data\webp: real files, gen\ = VP8L encoder, lossy\ = VP8, alph\ = ALPH/containers; tests\parity\gen_webp_cases.ps1) ---')
$count = 0
foreach ($dir in '', 'gen', 'lossy', 'alph') {
  $prefix = if ($dir) { "webp_${dir}_" } else { 'webp_real_' }
  foreach ($f in Get-ChildItem (Join-Path "tests\data\webp" "$dir\*.webp") | Sort-Object Name) {
    $s = Get-WebpSize $f.FullName
    $w = [int]$s[0]; $h = [int]$s[1]
    if ($w -lt 1 -or $h -lt 1 -or $w -gt 4096 -or $h -gt 4096) { $w = 33; $h = 17 }
    if ($w * $h -gt 40000) { $w = [Math]::Max(1, [int]($w / 4)); $h = [Math]::Max(1, [int]($h / 4)) }
    $rel = ($f.FullName.Substring($root.Length + 1)) -replace '\\', '/'
    $lines.Add("$prefix$($f.BaseName) | webp:$rel $w $h")
    $count++
  }
}
# resampled variants (scaled down / up, different aspect ratio)
foreach ($v in @(
  @('gen_pal7_33x17_up', 'tests/data/webp/gen/pal7_33x17.webp', 100, 60),
  @('gen_refs_101x23_down', 'tests/data/webp/gen/refs_101x23.webp', 40, 20),
  @('gen_all_1x1_up', 'tests/data/webp/gen/all_1x1.webp', 16, 16),
  @('lossy_gen_parts2_80x80_down', 'tests/data/webp/lossy/gen_parts2_80x80.webp', 31, 29),
  @('lossy_acro_crop_native', 'tests/data/webp/lossy/acro_crop-video.webp', 400, 280),
  @('lossy_acro_clip_up', 'tests/data/webp/lossy/acro_clip-maker.webp', 600, 400),
  @('real_acrobat_crop_video_native', 'tests/data/webp/acrobat_crop-video.webp', 400, 280),
  @('real_office_errorImage_up', 'tests/data/webp/office_errorImage.webp', 200, 200),
  @('real_thorvg_test_native', 'tests/data/webp/thorvg_test.webp', 511, 511),
  @('alph_simple_m1_up', 'tests/data/webp/alph/alph_gen_simple_33x17_m1_c1_f3.webp', 99, 51),
  @('alph_crop_m1_down', 'tests/data/webp/alph/alph_acro_crop-video_m1_c1_f2.webp', 133, 93))) {
  $lines.Add("webp_$($v[0]) | webp:$($v[1]) $($v[2]) $($v[3])")
  $count++
}
[IO.File]::WriteAllLines("$root\migration\cases.txt", $lines)
"added $count webp cases, total lines $($lines.Count)"


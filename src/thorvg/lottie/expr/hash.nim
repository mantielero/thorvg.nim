## Canonical expression hash shared by exprc and loader. Normalize line endings.
import std/strutils

proc normalizeExprSource*(s: string): string =
  ## Normalize CRLF/CR to LF for stable hashing across platforms.
  result = s.replace("\r\n", "\n").replace("\r", "\n")

proc fnv1a64*(s: string): uint64 =
  ## FNV-1a 64-bit over normalized bytes.
  result = 14695981039346656037'u64
  for c in s:
    result = result xor uint64(uint8(c))
    result = result * 1099511628211'u64

proc exprHash*(source: string): string =
  ## Canonical hash string for registry keys.
  let norm = normalizeExprSource(source)
  let h = fnv1a64(norm)
  result = toHex(h, 16).toLowerAscii()

import std/[unittest, math]
import thorvg/core/[str, compressor]

proc parsed(s: string): (float32, int) =
  var e = 0
  let v = toFloat(s, 0, e)
  (v, e)

proc near(a, b: float32, eps = 1e-5'f32): bool = abs(a - b) <= eps * max(1.0'f32, abs(b))

suite "str.toFloat":
  test "plain numbers and end index":
    check parsed("3.14abc") == (3.14'f32, 4)
    check parsed("42") == (42.0'f32, 2)
    check parsed("-.5") == (-0.5'f32, 3)
    check parsed("+7,8") == (7.0'f32, 2)
    check parsed("  12") == (12.0'f32, 4)
    check parsed("1.5.5") == (1.5'f32, 3)
    check parsed("10-5") == (10.0'f32, 2)

  test "exponents":
    check near(toFloat("1e3"), 1000.0'f32)
    check near(toFloat("1E-2"), 0.01'f32)
    check near(toFloat("2.5e+2"), 250.0'f32)
    check parsed("1e5x")[1] == 3
    check toFloat("1e40") == 0.0'f32 # overflow to inf is reported as 0
    check parsed("1e-50")[0] == 0.0'f32

  test "em unit consumes the unit":
    check parsed("10em") == (10.0'f32, 4)
    check parsed("2.5em") == (2.5'f32, 5)

  test "not a number":
    check parsed("abc") == (0.0'f32, 0)
    check parsed("") == (0.0'f32, 0)
    check parsed(".")[1] == 0
    check parsed("-")[1] == 0
    check parsed("5. 6") == (5.0'f32, 2)

  test "quirk: a lone e after digits is consumed unless at the end":
    check parsed("1e") == (1.0'f32, 1)
    check parsed("1ex") == (1.0'f32, 2)

  test "inf and nan":
    check toFloat("inf") == Inf
    check toFloat("-Infinity") == -Inf
    check toFloat("NaN").isNaN
    check parsed("info") == (Inf.float32, 3)

  test "float32 accumulation matches the original":
    check toFloat("0.1") == 0.1'f32
    check toFloat("123.456") == float32(123'u64) + float32(456'u64) / float32(1000'u64)
    check toFloat("16777217") == 16777216.0'f32

suite "str.paths":
  test "duplicate and append":
    check strDuplicate("hello", 3) == "hel"
    check strDuplicate("hi", 10) == "hi"
    check strDuplicate("") == ""
    check strAppend("ab", "cdef", 2) == "abcd"
    check strConcat("a", "b") == "ab"

  test "dirname, filename, fileext":
    check strDirname("a/b\\c.tar.gz") == "a/b\\"
    check strDirname("file.txt") == "file.txt"
    check strFilename("a/b\\c.tar.gz") == "c.tar"
    check strFilename("noext") == "noext"
    check strFilename("dir/.hidden") == ""
    check strFileExt("a/b/c.svg") == "svg"
    check strFileExt("c.tar.gz") == "gz"

suite "compressor":
  test "base64 decode":
    check b64Decode("SGVsbG8gV29ybGQ=") == "Hello World"
    check b64Decode("SGVsbG8") == "Hello"
    check b64Decode("TWE=") == "Ma"
    check b64Decode("TQ==") == "M"
    check b64Decode("SGVs\nbG8=") == "Hello"
    check b64Decode("") == ""

  test "base64 alphabets":
    check b64Decode("-_-_") == b64Decode("+/+/")
    check b64Decode("AAEC/w==") == "\x00\x01\x02\xff"

  test "djb2":
    check djb2Encode("") == 5381'u32
    check djb2Encode("a") == 5381'u32 * 33'u32 + 97'u32
    check djb2Encode("hello") == 261238937'u32
    check djb2Encode("\xff") == 5381'u32 * 33'u32 - 1'u32

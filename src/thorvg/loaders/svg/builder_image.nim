## SVG scene builder, part 3: `<image>` elements.
##
## Ported from `_imageBuildHelper` and the data-URI helpers of `modules/svg/tvgSvgBuilder.cpp`.
## An image is a `Picture` loaded from a `data:` URI (base64, or utf8 / url-encoded for
## svg) or from a file next to the svg (`ctx.svgPath`, D-T17b-1). Embedded `.svg` files
## are disabled, as in the original.

import std/[options, strutils]
import ../../core/[types, geom, compressor]
import ../../renderer/[paint, picture]
import ./[nodes, util, builder_geom, builder_comp]

type DataEncoding {.pure.} = enum
  Base64, Utf8

const MimeTypes = [
  ("jpeg", true, false), ("png", true, false), ("webp", true, false),
  ("svg+xml", true, true)]  ## name, allows base64, allows utf8

func hasPrefixAt(s: string, i: int, prefix: string): bool =
  i >= 0 and i + prefix.len <= s.len and cmpIgnoreCase(s[i ..< i + prefix.len], prefix) == 0

func parseDataHeader(href: string, pos: var int, mime: var string,
                     encoding: var DataEncoding): bool =
  ## `_isValidImageMimeTypeAndEncoding`: `pos` enters after `data:` and leaves at the payload.
  ## RFC2397 `data:[<mediatype>][;base64],<data>`.
  if not hasPrefixAt(href, pos, "image/"): return false
  pos += 6
  for (name, allowsBase64, allowsUtf8) in MimeTypes:
    if not hasPrefixAt(href, pos, name): continue
    pos += name.len
    mime = name
    while pos < href.len and href[pos] != ',':
      while pos < href.len and href[pos] != ';': inc pos
      if pos >= href.len: return false
      inc pos
      if allowsBase64 and hasPrefixAt(href, pos, "base64,"):
        pos += 7
        encoding = DataEncoding.Base64
        return true
      if allowsUtf8 and hasPrefixAt(href, pos, "utf8,"):
        pos += 5
        encoding = DataEncoding.Utf8
        return true
    if pos < href.len and href[pos] == ',' and allowsUtf8: # no encoding: utf8 is expected
      inc pos
      encoding = DataEncoding.Utf8
      return true
    return false
  false

proc loadImage(ctx: BuildCtx, pic: Picture, href: string): bool =
  if href.startsWith("data:"):
    var pos = 5
    var mime = ""
    var encoding = DataEncoding.Base64
    if not parseDataHeader(href, pos, mime, encoding): return false
    let payload = href[pos .. ^1]
    let decoded = if encoding == DataEncoding.Base64: b64Decode(payload) else: urlDecode(payload)
    return pic.load(decoded, mime) == Result.Success
  var path = href
  if path.startsWith("file://"): path = path[7 .. ^1]
  let dot = path.rfind('.')
  if dot >= 0 and path[dot .. ^1] == ".svg": return false # embedded svg files are disabled
  if not path.startsWith("/"): path = ctx.svgPath & path
  pic.load(path) == Result.Success

proc imageBuild*(ctx: BuildCtx, node: SvgNode, vBox: Box): Paint =
  let image = node.image
  if image.href.len == 0: return nil
  let pic = newPicture()
  if not loadImage(ctx, pic, image.href): return nil
  var w, h: float32
  var m = identity()
  if pic.size(w, h) == Result.Success and w > 0.0'f32 and h > 0.0'f32:
    m = affine(image.w / w, 0, image.x, 0, image.h / h, image.y)
  if node.transform.isSome: m = node.transform.get * m
  discard pic.transform(m)
  discard pic.filter(node.style.imageRendering)
  var p = applyFilter(ctx, pic, node, vBox)
  p = applyComposition(ctx, p, node, vBox)
  applyBlend(p, node)

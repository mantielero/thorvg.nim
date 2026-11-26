## Hash registry for compiled expressions (D2). Strict default: unknown hash => error.
import std/[tables, strutils]

type
  RegistryMode* = enum
    rmStrict        ## uncompiled/unknown hash => structured error
    rmIgnoreCounted ## caller explicitly requested; skip+count

  RegistryEntry* = object
    hash*: string
    source*: string
    procName*: string

  ExprRegistry* = object
    entries*: Table[string, RegistryEntry]
    mode*: RegistryMode
    ignored*: int
    errors*: seq[string]

proc initRegistry*(mode = rmStrict): ExprRegistry =
  ExprRegistry(entries: initTable[string, RegistryEntry](), mode: mode)

proc register*(r: var ExprRegistry; hash, source, procName: string) =
  r.entries[hash] = RegistryEntry(hash: hash, source: source, procName: procName)

proc lookup*(r: var ExprRegistry; hash, ctx: string): string =
  ## Returns procName or empty. In strict mode records error; in ignore mode counts.
  if hash in r.entries:
    return r.entries[hash].procName
  let msg = ctx & ": expression hash " & hash & " not in AOT registry"
  if r.mode == rmStrict:
    r.errors.add(msg)
  else:
    inc r.ignored
  return ""

proc hasHash*(r: ExprRegistry; hash: string): bool = hash in r.entries

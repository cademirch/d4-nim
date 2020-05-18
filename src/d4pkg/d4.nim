import ./d4_sys
import tables
import strformat

type D4* = object
  c: ptr d4_file_t
  chromosomes: OrderedTableRef[string, uint32]

type task_ctx = object
  name: string
  count: uint32
  sum: float64

proc `$`(c:task_ctx): string =
  return &"task_ctx(name:{$c.name}, count: {c.count}, sum: {c.sum})"

proc init(h:ptr d4_task_part_t, extra_data:pointer): pointer {.cdecl.} =
  var ctx = task_ctx(name: newString(20))
  doAssert h.d4_task_chrom(ctx.name[0].addr, ctx.name.len) >= 0
  var l:uint32
  var r:uint32
  doAssert h.d4_task_range(l.addr, r.addr) >= 0
  ctx.count = r - l
  #GC_ref(ctx)
  return ctx.addr.pointer

proc map*(d4:var D4, map_fn:proc(pos:uint32, values:seq[int32]): float64, n_cpus:int|uint32=1, chunk_size:int|uint32=10_000_000) =

  proc process(h: ptr d4_task_part_t, task_ctx_p: pointer, extra_data: pointer): cint {.cdecl.} =
    echo "process"
    if task_ctx_p == nil:
      echo "NULL:"
      return 1
    var
      pos: uint32
      r: uint32
      res = cast[task_ctx](task_ctx_p)
    doAssert h.d4_task_range(pos.addr, r.addr) >= 0
    echo "pos:", pos, " r:", r, " res:", res #== nil
    #echo " res:", res[]
    #echo " res.name:", res.name[0]
    echo "AFTER"

    var buffer = newSeqUninitialized[int32](10_000)
    while pos < r:
      echo "pos:", pos, " r:", r, " buffer.len:", buffer.len
      var count = h.d4_task_read_values(pos, buffer[0].addr, buffer.len)
      if count < 0:
        var error = newString(128)
        echo d4_error_message(error, error.len)
        break
      else:
        pos += count.uint32
        echo "count:", count, " buffer.len:", buffer.len

        for i in 0..<count:
          res.sum += buffer[i].float64

    echo "sum:", res.sum
    return 0

  proc clean(tasks: ptr d4_task_part_result_t, count: csize, extra_data: pointer): cint {.cdecl.} =
    echo "TODO: clean up!!"
    return 0

  var task = d4_task_desc_t(mode: D4_TASK_READ,
                            part_size_limit: chunk_size.uint32,
                            num_cpus: n_cpus.uint32,
                            part_context_create_cb: init,
                            part_finalize_cb: clean,
                            part_process_cb: process,
                            extra_data: nil)

  echo "created task:", task
  var res = d4.c.d4_file_run_task(task.addr)
  if res != 0:
    var error = newString(128)
    echo d4_error_message(error, error.len)

proc fill_chromosomes*(d4:var D4): OrderedTableRef[string, uint32] =
  var mt:d4_file_metadata_t
  doAssert 0 == d4.c.d4_file_load_metadata(mt.addr)
  result = newOrderedTable[string, uint32]()
  for i in 0..<mt.chrom_count.int:
    result[$mt.chrom_name[i]] = cast[ptr UncheckedArray[uint32]](mt.chrom_size)[i]
  mt.addr.d4_file_metadata_clear

proc open*(d4:var D4, path:string, mode="r"): bool {.discardable.} =
  d4.c = d4_open(path, mode)
  if d4.c != nil:
    d4.chromosomes = d4.fill_chromosomes
  return d4.c != nil

proc close*(d4: var D4) =
  ## close d4 file and release memory.
  if 0 != d4.c.d4_close:
    raise newException(IOError, "error closing d4 file")
  d4.chromosomes = nil
  d4.c = nil

proc same(a:string, b:string): bool {.inline.} =
  if a.len < b.len: return false
  for i, c in b:
    if a[i] != c: return false
  return true

iterator query*(d4:var D4, chrom:string, start:int|uint32=0, stop:int|uint32=uint32.high): tuple[start: uint32, stop:uint32, value:int32] =
  if chrom notin d4.chromosomes:
    raise newException(KeyError, &"{chrom} not in known chromosomes")

  var stop = min(d4.chromosomes[chrom], stop.uint32)
  var start = start.uint32

  doAssert 0 == d4.c.d4_file_seek(chrom, start)
  var data = newSeq[d4_interval_t](1000)
  var done = false
  var qchrom = newString(20)
  var pos:uint32

  while not done:
    discard d4.c.d4_file_tell(qchrom, qchrom.len, pos.addr)
    if not qchrom.same(chrom): break

    var count = d4.c.d4_file_read_intervals(data[0].addr, data.len)

    for i in 0..<count:
      yield (max(start, data[i].left), min(stop, data[i].right), data[i].value)
      if data[i].right >= stop:
        done = true
        break

    if count.int < data.len: break

proc values*(d4:var D4, chrom:string, start:int|uint32=0, stop:int|uint32=uint32.high): seq[int32] =

  var stop = min(d4.chromosomes[chrom], stop.uint32)
  var start = start.uint32
  result = newSeqUninitialized[int32](stop - start)
  for iv in d4.query(chrom, start, stop):
    for p in iv.start ..< iv.stop:
      result[p - start] = iv.value


when isMainModule:
  import math
  var d4f:D4
  doAssert d4f.open("hg002.d4")
  echo d4f.chromosomes # ordered table
  echo d4f.chromosomes["1"]

  #for iv in d4f.query("1", 249_200_100):
  #  echo iv
  var vals = d4f.values("1", 249_200_100, 249240621)
  doAssert vals.len.uint32 == 249240621'u32 - 249_200_100'u32
  #echo vals.len
  #echo vals

  proc fn(pos:uint32, values:seq[int32]): float64 =
    return values.sum.float32
  d4f.close
  doAssert d4f.open("hg002.d4")

  d4f.map(fn)

  d4f.close



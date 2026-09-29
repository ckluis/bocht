// FS.rename_seg — atomic rename of a WAL segment into the archive.
//
// Round 3 item 14 (segmented WAL): after a snapshot is written, fsync'd,
// and validated, covered active segments are moved to
// wal/archive/YYYY/MM/ with rename(2), which is atomic on POSIX: after a
// crash a segment is either still in wal/active/ (replayed, harmless —
// WAL replay is idempotent) or fully in the archive (skipped by replay).
// It is never half-moved and never deleted by the move.
//
// Returns U32 1 on success, 0 on failure. The caller fsyncs both
// directories afterwards via FS.sync_dir so the rename survives OS
// crashes. Power loss is out of scope, same as the rest of the service.

#include <stdio.h>

Term fs_rename_seg_run(Env e, Term* f, IoWork* w) {
  size_t n1 = 0, n2 = 0;
  char* from = io_cstr(e, f[0], &n1);
  char* to = io_cstr(e, f[1], &n2);
  uint32_t ok = rename(from, to) == 0 ? 1 : 0;
  free(from);
  free(to);
  return (Term)ok;
}

static void __attribute__((constructor)) fs_rename_seg_use(void) {
  io_eff(CID_FS_RENAME_SEG, fs_rename_seg_run, 0);
}

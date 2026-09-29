// FS.unlink — delete one archived WAL segment.
//
// Round 3 item 14 (segmented WAL): the purge scanner calls this for
// archived segments older than the retention window. Returns U32 1 on
// success, 0 on failure. Deleting a path that is already gone (ENOENT)
// returns 1: purge is idempotent, and a concurrent or retried delete must
// not read as a failure.

#include <unistd.h>
#include <errno.h>

Term fs_unlink_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  uint32_t ok;
  if (unlink(path) == 0) ok = 1;
  else ok = (errno == ENOENT) ? 1 : 0;
  free(path);
  return (Term)ok;
}

static void __attribute__((constructor)) fs_unlink_use(void) {
  io_eff(CID_FS_UNLINK, fs_unlink_run, 0);
}

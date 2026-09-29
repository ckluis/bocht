// FS.sync_dir — fsync(2) a directory fd.
//
// Round 3 item 14 (segmented WAL): after mkdir -p creates wal/active/ or
// a wal/archive/YYYY/MM/ destination, and after rename(2) moves segments
// into the archive, the service fsyncs the affected directories so the
// name creations survive OS crashes (file data is already fsync'd by the
// write path; without a directory fsync the names could vanish on OS
// crash even though the data is durable). Best-effort: returns U32 1 when
// the fsync succeeded, 0 otherwise. Power loss is out of scope, same as
// the rest of the service.

#include <fcntl.h>
#include <unistd.h>

Term fs_sync_dir_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  int fd = open(path, O_RDONLY);
  uint32_t ok = 0;
  free(path);
  if (fd >= 0) {
    ok = fsync(fd) == 0 ? 1 : 0;
    close(fd);
  }
  return (Term)ok;
}

static void __attribute__((constructor)) fs_sync_dir_use(void) {
  io_eff(CID_FS_SYNC_DIR, fs_sync_dir_run, 0);
}

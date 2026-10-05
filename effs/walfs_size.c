// FS.file_size — size in bytes of a regular file.
//
// Round 3 item 14 (segmented WAL): the rollover decision stats the current
// active segment before each append. Returns U32 0 when the file is
// missing (a fresh segment: append creates it), when it is not a regular
// file (e.g. the failure-injection directory used by tests — the
// subsequent open in append mode then fails honestly and the write
// surfaces as 500 wal_write_failed), or when it exceeds 32 bits
// (segments are capped far below that; saturates).

#include <sys/types.h>
#include <sys/stat.h>

Term fs_file_size_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  struct stat st;
  uint32_t sz = 0;
  if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) {
    sz = st.st_size > (off_t)0xffffffffu ? 0xffffffffu : (uint32_t)st.st_size;
  }
  free(path);
  return (Term)sz;
}

static void __attribute__((constructor)) fs_file_size_use(void) {
  io_eff(CID_FS_FILE_SIZE, fs_file_size_run, 0);
}

// FS.file_mtime — modification time of a file, seconds since the epoch.
//
// Round 3 item 14 (segmented WAL): the purge scanner compares each
// archived segment's mtime against the retention window. Returns U32 0 on
// stat failure only if the clock is also unavailable; otherwise a stat
// failure returns the CURRENT time, i.e. age zero: a segment whose mtime
// cannot be read is never purged. Fail-closed by construction.

#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>

Term fs_file_mtime_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  struct stat st;
  time_t now = time(NULL);
  uint32_t mt = now < 0 ? 0 : (uint32_t)now;
  if (stat(path, &st) == 0) mt = (uint32_t)st.st_mtime;
  free(path);
  return (Term)mt;
}

static void __attribute__((constructor)) fs_file_mtime_use(void) {
  io_eff(CID_FS_FILE_MTIME, fs_file_mtime_run, 0);
}

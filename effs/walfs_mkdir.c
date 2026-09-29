// FS.mkdir_p — recursive directory creation (mkdir -p).
//
// Round 3 item 14 (segmented WAL): the service lays out wal/active/ and
// wal/archive/YYYY/MM/ at boot, and the archive path's year/month parents
// at snapshot time. Base 2.0.18 has no directory-creation primitive, so
// this custom effect does it natively.
//
// Returns U32 1 when the directory exists afterwards (created or already
// present), 0 on failure. An existing non-directory at the path is a
// failure (0), not silent success: later segment writes would fail anyway,
// and the service must see the error rather than assume the layout.
//
// Durability note: mkdir_p only creates the entries; the caller fsyncs the
// parent directory via FS.sync_dir where OS-crash durability of the new
// name matters (archive destination after snapshot). Power loss is out of
// scope, same as the rest of the service.

#include <sys/types.h>
#include <sys/stat.h>

static uint32_t walfs_mkdir_p(const char* path) {
  char tmp[4096];
  size_t len = strlen(path);
  size_t i;
  struct stat st;
  if (len == 0 || len >= sizeof(tmp)) return 0;
  memcpy(tmp, path, len + 1);
  while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';
  for (i = 1; i < len; i++) {
    if (tmp[i] == '/') {
      tmp[i] = '\0';
      if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
      tmp[i] = '/';
    }
  }
  if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
  if (stat(tmp, &st) != 0) return 0;
  return S_ISDIR(st.st_mode) ? 1 : 0;
}

Term fs_mkdir_p_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  uint32_t ok = walfs_mkdir_p(path);
  free(path);
  return (Term)ok;
}

static void __attribute__((constructor)) fs_mkdir_p_use(void) {
  io_eff(CID_FS_MKDIR_P, fs_mkdir_p_run, 0);
}

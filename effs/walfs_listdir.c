// FS.list_dir — list directory entries, one name per line.
//
// Round 3 item 14 (segmented WAL): the service enumerates wal/active/ for
// segment replay and rollover decisions, and walks wal/archive/ for the
// purge scanner. Base 2.0.18 has no directory-enumeration primitive.
//
// Returns a String of entry names joined by '\n' (no trailing newline).
// "." and ".." are skipped. Returns "" when the directory cannot be
// opened — callers treat that as "no entries", which is the safe default
// (boot sees no segments; purge sees nothing to delete).

#include <sys/types.h>
#include <dirent.h>

Term fs_list_dir_run(Env e, Term* f, IoWork* w) {
  size_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  DIR* d = opendir(path);
  char* buf = NULL;
  size_t len = 0, cap = 0;
  free(path);
  if (d) {
    struct dirent* de;
    while ((de = readdir(d)) != NULL) {
      size_t nl;
      if (de->d_name[0] == '.' &&
          (de->d_name[1] == '\0' ||
           (de->d_name[1] == '.' && de->d_name[2] == '\0')))
        continue;
      nl = strlen(de->d_name);
      if (len + nl + 2 > cap) {
        size_t ncap = cap ? cap * 2 : 256;
        char* nb;
        while (ncap < len + nl + 2) ncap *= 2;
        nb = realloc(buf, ncap);
        if (!nb) break;
        buf = nb;
        cap = ncap;
      }
      if (len > 0) buf[len++] = '\n';
      memcpy(buf + len, de->d_name, nl);
      len += nl;
    }
    closedir(d);
  }
  {
    Term r = io_str(e, buf ? buf : "", len);
    free(buf);
    return r;
  }
}

static void __attribute__((constructor)) fs_list_dir_use(void) {
  io_eff(CID_FS_LIST_DIR, fs_list_dir_run, 0);
}

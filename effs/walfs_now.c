// FS.now_sec — current wall-clock epoch time in seconds.
// Round 3 item 14: IO.now() is monotonic (uptime), not wall-clock, so the
// segmented WAL needs this for archive YYYY/MM dating and purge ages.
#include <time.h>
#include <stdint.h>

Term fs_now_sec_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  time_t now = time(NULL);
  uint32_t t = now < 0 ? 0 : (uint32_t)now;
  return (Term)t;
}

static void __attribute__((constructor)) fs_now_sec_use(void) {
  io_eff(CID_FS_NOW_SEC, fs_now_sec_run, 0);
}

// File.sync — fsync(2) for a File handle.
//
// Base 2.0.18 has no sync primitive: File.write reaches the kernel page
// cache, so durability covers process crashes only, not OS crashes or
// power loss. WAL commit appends and snapshot writes call this before
// close, making them durable against OS crashes too (on local disks).
// Not a power-loss claim: that also depends on the drive's cache behavior,
// and newly created files would need a parent-directory fsync for the
// strongest POSIX durability argument.

static void file_sync_call(IoWork* w) {
  int fd = (int)w->hand;
  int r = fsync(fd);
  io_sys_end(w, r);
}

static Term file_sync_pack(Env e, IoWork* w) {
  Term r = w->code != 0 ? io_fail(e, w->code, NULL)
    : io_done(e, term_pak(CID_UNIT, 0));
  return io_tup(e, io_hand(w->hand), r);
}

Term file_sync_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  return io_work(w, file_sync_call, file_sync_pack);
}

static void __attribute__((constructor)) file_sync_use(void) {
  io_eff(CID_FILE_SYNC, file_sync_run, 0);
}

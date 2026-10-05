// File.sync — JS backend stub.
//
// Best-effort: flush via the sync binding when the runtime exposes one,
// otherwise a no-op success. fsync durability is a native-only guarantee;
// the campaign builds and tests the native binary exclusively.

function file_sync(file) {
  const sys = io_sys();
  if (sys.fsync) {
    const r = Number(sys.fsync(Number(file)));
    if (r < 0) return io_tup(file, io_fail(sys.errno()));
  }
  return io_tup(file, io_done({ $: "Unit" }));
}

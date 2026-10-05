// FS.sync_dir — JS backend stub.
//
// The JS effect runtime used here exposes no directory-fsync binding, so
// this is a no-op on this backend (returns 0, failure). The native backend
// performs the real fsync. The campaign builds and tests the native
// binary exclusively.

function fs_sync_dir(path) {
  return 0;
}

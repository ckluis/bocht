// FS.unlink — JS backend stub.
//
// The JS effect runtime used here exposes no unlink binding, so deletion
// is unavailable on this backend (returns 0, failure). The native backend
// performs the real unlink. The campaign builds and tests the native
// binary exclusively.

function fs_unlink(path) {
  return 0;
}

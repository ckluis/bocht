// FS.mkdir_p — JS backend stub.
//
// The JS effect runtime used here exposes no mkdir binding, so directory
// creation is unavailable on this backend (returns 1 without doing
// anything). The native backend performs the real recursive mkdir. The
// campaign builds and tests the native binary exclusively.

function fs_mkdir_p(path) {
  return 1;
}

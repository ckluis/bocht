// FS.list_dir — JS backend stub.
//
// The JS effect runtime used here exposes no directory-listing binding,
// so enumeration is unavailable on this backend (returns "", i.e. "no
// entries"). The native backend returns the real newline-joined listing.
// The campaign builds and tests the native binary exclusively.

function fs_list_dir(path) {
  return "";
}

# Keep independent packages reusable when unrelated parts of the release change.
# The updater still retains the complete authenticated release source separately.
{
  lib,
  source,
  paths,
}:
lib.cleanSourceWith {
  src = source;
  name = "cybexos-package-source";
  filter =
    path: type:
    let
      root = toString source;
      relative = lib.removePrefix (root + "/") path;
    in
    path == root
    || builtins.any (
      selected:
      relative == selected
      || lib.hasPrefix (selected + "/") relative
      || (type == "directory" && lib.hasPrefix (relative + "/") selected)
    ) paths;
}

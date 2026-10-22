#!/usr/bin/env python3
"""Offline regression fixtures for transactional upstream installers."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import textwrap
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)


def run(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if env:
        environment.update(env)
    return subprocess.run(
        argv,
        cwd=ROOT,
        env=environment,
        input=input_text,
        text=True,
        capture_output=True,
    )


def tree_snapshot(root: Path) -> list[tuple[str, str, int, bytes | str]]:
    snapshot: list[tuple[str, str, int, bytes | str]] = []
    for path in sorted(root.rglob("*"), key=lambda item: str(item.relative_to(root))):
        relative = str(path.relative_to(root))
        mode = path.lstat().st_mode & 0o7777
        if path.is_symlink():
            snapshot.append((relative, "symlink", mode, os.readlink(path)))
        elif path.is_dir():
            snapshot.append((relative, "directory", mode, b""))
        else:
            snapshot.append((relative, "file", mode, path.read_bytes()))
    return snapshot


def common_stub(path: Path) -> None:
    executable(
        path,
        r'''
cybexos_curl() { curl "$@"; }
gh_api_fetch() {
  /usr/bin/cp -- "$MOCK_RELEASE_JSON" "$3"
  printf '%s\n' "$1" > "$MOCK_API_LOG"
}
atomic_current_swap() {
  local root=$1 target=$2
  ln -sfn "$target" "$root/current.new"
  /usr/bin/mv -Tf "$root/current.new" "$root/current"
}
verify_sha256() {
  [[ $(sha256sum "$1" | awk '{print $1}') == "$2" ]]
}
prune_version_dirs() {
  [[ ${MOCK_PRUNE_FAIL:-0} != 1 ]]
}
emit_changed() { echo "CHANGED: $*"; }
emit_unchanged() { echo "UNCHANGED: $*"; }
cybexos_restorecon() { return 0; }
''',
    )


def render_installer(source: Path, destination: Path, root: Path, common: Path) -> None:
    rendered = source.read_text().replace(
        "source /usr/local/libexec/cybexos-common.sh",
        f"source {shlex.quote(str(common))}",
    )
    replacements = {
        "/var/cache/cybexos-upstream": str(root / "cache"),
        "/var/cache/cybexos-source-builds": str(root / "source-cache"),
        "/var/lib/cybexos-upstream": str(root / "state"),
        "/opt/cybexos-apps": str(root / "apps"),
        "/opt/cybexos-builds": str(root / "builds"),
        "/usr/local/share/fonts": str(root / "fonts"),
        "/usr/local/bin": str(root / "bin"),
    }
    for original, replacement in replacements.items():
        rendered = rendered.replace(original, replacement)
    executable(destination, rendered.removeprefix("#!/usr/bin/env bash\n"))


def release_json(path: Path, tag: str, asset: str, digest: str) -> None:
    path.write_text(
        json.dumps(
            {
                "tag_name": tag,
                "draft": False,
                "prerelease": False,
                "assets": [
                    {
                        "name": asset,
                        "browser_download_url": f"https://example.invalid/{asset}",
                        "digest": f"sha256:{digest}",
                    }
                ],
            }
        )
    )


def github_environment(root: Path, package: str = "") -> dict[str, str]:
    mock_bin = root / "mock-bin"
    mock_bin.mkdir(parents=True, exist_ok=True)
    (root / "bin").mkdir(parents=True, exist_ok=True)
    executable(
        mock_bin / "rpm",
        r'''
name=${@: -1}
if [[ $1 == -q ]]; then
  [[ $name == "$MOCK_PACKAGE" ]] || exit 1
  [[ -z ${MOCK_INSTALLED_MARKER:-} || -f $MOCK_INSTALLED_MARKER ]] || exit 1
  if [[ ${2:-} == --qf ]]; then printf '%s' "$MOCK_NEVRA"; fi
  exit 0
fi
if [[ $1 == -qp && ${2:-} == --qf ]]; then
  if [[ $3 == '%{NAME}' ]]; then printf '%s' "${MOCK_ASSET_PACKAGE:-$MOCK_PACKAGE}";
  else printf '%s' "$MOCK_NEVRA"; fi
  exit 0
fi
exit 2
''',
    )
    executable(mock_bin / "dnf", '''
printf '%s\\n' "$*" >> "$MOCK_DNF_LOG"
if [[ -n ${MOCK_DNF_EXPECTED:-} ]]; then
  [[ ${@: -1} == *.rpm ]]
  [[ $(/usr/bin/sha256sum "${@: -1}" | awk '{print $1}') == "$MOCK_DNF_EXPECTED" ]]
fi
[[ -z ${MOCK_INSTALLED_MARKER:-} ]] || touch "$MOCK_INSTALLED_MARKER"
''')
    executable(mock_bin / "curl", 'echo "unexpected curl invocation" >&2; exit 99\n')
    executable(mock_bin / "restorecon", 'exit 0\n')
    return {
        "PATH": f"{mock_bin}:/usr/bin:/bin",
        "GH_TOKEN": "",
        "MOCK_PACKAGE": package,
        "MOCK_NEVRA": f"{package or 'absent'}-1.0-1.x86_64",
        "MOCK_DNF_LOG": str(root / "dnf.log"),
        "MOCK_API_LOG": str(root / "api.log"),
    }


def test_prune_count() -> None:
    common = ROOT / "roles/apps/files/cybexos-common.sh"
    for current_name, expected in (
        ("v5", {"v3", "v4", "v5"}),
        ("v1", {"v1", "v4", "v5"}),
        (None, {"v3", "v4", "v5"}),
    ):
        with tempfile.TemporaryDirectory(prefix="cybexos-prune.") as temporary:
            root = Path(temporary)
            versions = root / "versions"
            versions.mkdir()
            for index in range(1, 6):
                version = versions / f"v{index}"
                version.mkdir()
                os.utime(version, (index, index))
            if current_name:
                (root / "current").symlink_to(f"versions/{current_name}")
            result = run(
                [
                    "bash",
                    "-c",
                    f"source {shlex.quote(str(common))}; "
                    f"prune_version_dirs {shlex.quote(str(root))} 3",
                ]
            )
            assert result.returncode == 0, result.stderr
            assert {entry.name for entry in versions.iterdir()} == expected


def test_github_rpm_convergence_and_tag_endpoint() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-github-rpm.") as temporary:
        root = Path(temporary)
        common = root / "common.sh"
        installer = root / "github-release-install"
        common_stub(common)
        render_installer(
            ROOT / "roles/apps/files/github-release-install", installer, root, common
        )
        env = github_environment(root, "demo")
        release = root / "release.json"
        payload = b"verified rpm fixture\n"
        digest = hashlib.sha256(payload).hexdigest()
        release_json(release, "v1", "demo.rpm", digest)
        env["MOCK_RELEASE_JSON"] = str(release)
        cache = root / "cache/demo/v1"
        cache.mkdir(parents=True)
        (cache / "demo.rpm").write_bytes(payload)
        state = root / "state/demo"
        state.mkdir(parents=True)
        (state / "version").write_text(
            "tag=v1 checksum=sha256:" + ("0" * 64) + "\n"
        )
        (state / "nevra").write_text(env["MOCK_NEVRA"] + "\n")

        argv = [
            str(installer),
            "demo",
            "owner/repo",
            "^demo[.]rpm$",
            "rpm",
            "v1",
            f"sha256:{digest}",
        ]
        result = run(argv, env=env)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "CHANGED: installed demo v1" in result.stdout
        assert "reinstall" in Path(env["MOCK_DNF_LOG"]).read_text()
        assert "--setopt=install_weak_deps=False" in Path(env["MOCK_DNF_LOG"]).read_text()
        assert (state / "version").read_text().strip() == (
            f"tag=v1 checksum=sha256:{digest}"
        )
        assert (state / "nevra").read_text().strip() == env["MOCK_NEVRA"]
        assert not Path(env["MOCK_API_LOG"]).exists()
        assert "releases?per_page=" not in (
            ROOT / "roles/apps/files/github-release-install"
        ).read_text()

        # The authorized tag and checksum already describe the intact package,
        # so convergence makes no GitHub round trip and survives being offline.
        Path(env["MOCK_DNF_LOG"]).write_text("")
        Path(env["MOCK_API_LOG"]).unlink(missing_ok=True)
        offline = dict(env, MOCK_RELEASE_JSON=str(root / "offline.json"))
        result = run(argv, env=offline)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == "UNCHANGED: demo v1"
        assert Path(env["MOCK_DNF_LOG"]).read_text() == ""
        assert not Path(env["MOCK_API_LOG"]).exists()

        # On a cache miss, the pin must still agree with GitHub's digest.
        (state / "version").unlink()
        (cache / "demo.rpm").unlink()
        release_json(release, "v1", "demo.rpm", "f" * 64)
        result = run(argv, env=env)
        assert result.returncode == 75
        assert "disagrees with GitHub's release digest" in result.stderr
        assert Path(env["MOCK_DNF_LOG"]).read_text() == ""
        assert Path(env["MOCK_API_LOG"]).read_text().strip().endswith(
            "/releases/tags/v1"
        )


def make_zip(path: Path, files: dict[str, bytes], executable_names: set[str] | None = None) -> None:
    executable_names = executable_names or set()
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in files.items():
            info = zipfile.ZipInfo(name)
            mode = 0o100755 if name in executable_names else 0o100644
            info.external_attr = mode << 16
            archive.writestr(info, payload)



def github_cache_fixture(
    root: Path, kind: str, *, rpm_asset: bool = False, tag: str = "v1"
) -> tuple[dict[str, str], list[str], Path, Path]:
    """Run the production installer/common helpers; mock only external commands."""
    common = root / "common.sh"
    common.write_text("source " + shlex.quote(str(ROOT / "roles/apps/files/cybexos-common.sh")) + "\n")
    installer = root / "github-release-install"
    render_installer(ROOT / "roles/apps/files/github-release-install", installer, root, common)
    rpm_mode = kind == "rpm" or rpm_asset
    env = github_environment(root, "demo" if rpm_mode else "")
    env["MOCK_INSTALLED_MARKER"] = str(root / "rpm-installed")
    env["MOCK_NETWORK_LOG"] = str(root / "network.log")
    env["MOCK_DOWNLOAD"] = str(root / "payload")
    env["MOCK_RELEASE_JSON"] = str(root / "release.json")
    (root / "temporary").mkdir()
    env["TMPDIR"] = str(root / "temporary")
    executable(
        root / "mock-bin/curl",
        r"""
output=""
previous=""
api=""
for argument in "$@"; do
  if [[ $previous == -o || $previous == --output ]]; then output=$argument; fi
  [[ $argument != https://api.github.com/* ]] || api=$argument
  previous=$argument
done
printf '%s\n' "$*" >> "$MOCK_NETWORK_LOG"
if [[ -n $api ]]; then
  printf '%s\n' "$api" >> "$MOCK_API_LOG"
  if [[ ${MOCK_NETWORK_OK:-0} == 1 ]]; then
    /usr/bin/cp -- "$MOCK_RELEASE_JSON" "$output"
    printf 200
  else
    : > "$output"
    printf 403
  fi
else
  [[ ${MOCK_NETWORK_OK:-0} == 1 ]] || exit 99
  /usr/bin/cp -- "$MOCK_DOWNLOAD" "$output"
fi
""",
    )
    asset_name = "demo.rpm" if rpm_mode else ("demo" if kind == "binary" else "demo.zip")
    cache = root / "cache/demo" / tag.replace("/", "_") / asset_name
    cache.parent.mkdir(parents=True)
    if rpm_mode:
        cache.write_bytes(b"inventory-authorized RPM fixture\n")
    elif kind == "binary":
        cache.write_bytes(b"#!/usr/bin/env bash\necho verified\n")
    else:
        contents = {"LICENSE.txt": b"bundled license\n"}
        contents["Demo.ttf" if kind == "font" else "demo"] = b"verified payload\n"
        make_zip(cache, contents, set() if kind == "font" else {"demo"})
    digest = hashlib.sha256(cache.read_bytes()).hexdigest()
    env["MOCK_DNF_EXPECTED"] = digest
    Path(env["MOCK_DOWNLOAD"]).write_bytes(cache.read_bytes())
    release_json(Path(env["MOCK_RELEASE_JSON"]), tag, asset_name, digest)
    argv = [str(installer), "demo", "owner/repo", "^" + asset_name.replace(".", "[.]") + "$",
            kind, tag, f"sha256:{digest}"]
    install_root = root / ("fonts" if kind == "font" else "apps") / "demo"
    return env, argv, cache, install_root


def test_github_verified_cache_kinds_without_network() -> None:
    for kind, rpm_asset in (("rpm", True), ("archive-auto", True), ("archive", False),
                            ("archive-auto", False), ("font", False), ("binary", False)):
        with tempfile.TemporaryDirectory(prefix="cybexos-pinned-cache.") as temporary:
            root = Path(temporary)
            env, argv, cache, install_root = github_cache_fixture(
                root, kind, rpm_asset=rpm_asset, tag="release/v1")
            result = run(argv, env=env)
            assert result.returncode == 0, (kind, result.stdout, result.stderr)
            assert result.stdout.strip() == "CHANGED: installed demo release/v1"
            assert not Path(env["MOCK_NETWORK_LOG"]).exists()
            assert not list(Path(env["TMPDIR"]).iterdir())
            if rpm_asset:
                assert (root / "rpm-installed").exists()
                assert (root / "state/demo/version").read_text().strip() == (
                    f"tag=release/v1 checksum={argv[-1]}")
            elif kind == "binary":
                assert (install_root / "current/bin/demo").read_bytes() == cache.read_bytes()
            else:
                assert (install_root / "current/LICENSE.txt").read_bytes() == b"bundled license\n"
                assert (install_root / ("current/Demo.ttf" if kind == "font" else "current/bin/demo")).is_file()
            # Healthy installed convergence still needs neither cache nor API.
            cache.unlink()
            result = run(argv, env=env)
            assert result.returncode == 0, (kind, result.stdout, result.stderr)
            assert result.stdout.strip() == "UNCHANGED: demo release/v1"
            assert not Path(env["MOCK_NETWORK_LOG"]).exists()
            assert not list(Path(env["TMPDIR"]).iterdir())


def test_github_cache_misses_and_unsafe_paths() -> None:
    for case in ("missing", "corrupt", "wrong-tag", "wrong-regex", "ambiguous", "directory-asset",
                 "invalid-checksum", "no-checksum", "symlink-asset", "symlink-tag",
                 "symlink-parent", "dot-tag", "traversal-name"):
        with tempfile.TemporaryDirectory(prefix="cybexos-cache-reject.") as temporary:
            root = Path(temporary)
            env, argv, cache, install_root = github_cache_fixture(root, "binary")
            if case == "missing":
                cache.unlink()
            elif case == "corrupt":
                cache.write_bytes(b"unchecked corrupt bytes\n")
            elif case == "wrong-tag":
                cache.parent.rename(cache.parent.with_name("v2"))
            elif case == "wrong-regex":
                cache.rename(cache.with_name("different-asset"))
            elif case == "ambiguous":
                argv[3] = "^demo"
                cache.with_name("demo-other").write_bytes(cache.read_bytes())
            elif case == "directory-asset":
                cache.unlink()
                cache.mkdir()
                (cache / "nested-payload").write_bytes(Path(env["MOCK_DOWNLOAD"]).read_bytes())
            elif case in ("invalid-checksum", "no-checksum"):
                argv[-1] = "sha256:bad" if case == "invalid-checksum" else ""
            elif case == "symlink-asset":
                cache.unlink()
                cache.symlink_to(root / "payload")
            elif case in ("symlink-tag", "symlink-parent"):
                target = cache.parent if case == "symlink-tag" else cache.parent.parent
                outside = root / "outside"
                target.rename(outside)
                target.symlink_to(outside, target_is_directory=True)
            elif case == "dot-tag":
                argv[-2] = ".."
            elif case == "traversal-name":
                argv[1] = "demo/../demo"
            before = tree_snapshot(root / "cache")
            result = run(argv, env=env)
            assert not list(Path(env["TMPDIR"]).iterdir())
            assert result.returncode not in (0, 75), (case, result.stdout, result.stderr)
            assert "CHANGED:" not in result.stdout
            assert not (install_root / "current").exists()
            assert not list((root / "bin").iterdir())
            assert not Path(env["MOCK_DNF_LOG"]).exists()
            # The ordinary API helper may create its metadata directory on a
            # miss, but must not change any existing payload or follow a link.
            after = [entry for entry in tree_snapshot(root / "cache") if entry[0] != "demo/api"]
            assert after == before, case
            unsafe = case.startswith("symlink-") or case in ("dot-tag", "traversal-name")
            if unsafe:
                assert "Refusing unsafe cached asset path" in result.stderr, (case, result.stderr)
                assert not Path(env["MOCK_NETWORK_LOG"]).exists()
            else:
                assert "HTTP 403" in result.stderr, (case, result.stderr)
                assert Path(env["MOCK_API_LOG"]).read_text().strip().endswith("/releases/tags/v1")


def test_github_cache_miss_download_and_rpm_identity() -> None:
    for case in ("missing", "corrupt", "ambiguous", "digest-conflict", "wrong-rpm-name", "unpinned-rpm"):
        with tempfile.TemporaryDirectory(prefix="cybexos-cache-fallback.") as temporary:
            root = Path(temporary)
            env, argv, cache, install_root = github_cache_fixture(
                root, "archive-auto", rpm_asset=case in ("wrong-rpm-name", "unpinned-rpm"))
            env["MOCK_NETWORK_OK"] = "1"
            if case == "wrong-rpm-name":
                env["MOCK_ASSET_PACKAGE"] = "unauthorized-package"
            elif case == "unpinned-rpm":
                argv[-1] = ""
            else:
                if case == "ambiguous":
                    argv[3] = "^demo"
                    cache.with_name("demo-other.zip").write_bytes(cache.read_bytes())
                else:
                    cache.unlink()
                    if case == "corrupt":
                        cache.write_bytes(b"bad cache\n")
                if case == "digest-conflict":
                    release_json(Path(env["MOCK_RELEASE_JSON"]), "v1", "demo.zip", "f" * 64)
            result = run(argv, env=env)
            assert not list(Path(env["TMPDIR"]).iterdir())
            if case in ("digest-conflict", "wrong-rpm-name", "unpinned-rpm"):
                assert result.returncode not in (0, 75), (case, result.stdout, result.stderr)
                assert "CHANGED:" not in result.stdout
                assert not Path(env["MOCK_DNF_LOG"]).exists()
                assert not (install_root / "current").exists()
                message = {"wrong-rpm-name": "expected demo package", "digest-conflict": "disagrees",
                           "unpinned-rpm": "requires an inventory-pinned release tag and SHA-256"}[case]
                assert message in result.stderr
            else:
                assert result.returncode == 0, (case, result.stdout, result.stderr)
                assert (install_root / "current/bin/demo").read_bytes() == b"verified payload\n"
            if case == "wrong-rpm-name":
                assert not Path(env["MOCK_NETWORK_LOG"]).exists()
            else:
                assert Path(env["MOCK_API_LOG"]).exists()
                if case in ("missing", "corrupt"):
                    assert cache.read_bytes() == Path(env["MOCK_DOWNLOAD"]).read_bytes()


def test_github_cache_snapshot_and_final_verification() -> None:
    for mutation in ("replace-cache", "delete-cache", "corrupt-copy", "delete-copy", "delete-before-verify"):
        with tempfile.TemporaryDirectory(prefix="cybexos-cache-mutation.") as temporary:
            root = Path(temporary)
            env, argv, cache, install_root = github_cache_fixture(root, "binary")
            env.update(MOCK_CACHE=str(cache), MOCK_MUTATION=mutation)
            executable(
                root / "mock-bin/jq",
                r"""
if [[ ${2:-} == .digest && $MOCK_MUTATION == delete-before-verify ]]; then
  rm -- "$TMPDIR"/*/demo
fi
exec /usr/bin/jq "$@"
""",
            )
            executable(
                root / "mock-bin/sha256sum",
                r"""
case "$MOCK_MUTATION" in
  replace-cache) printf unchecked > "$MOCK_CACHE" ;;
  delete-cache) rm -- "$MOCK_CACHE" ;;
  corrupt-copy) printf unchecked > "$1" ;;
  delete-copy) rm -- "$1" ;;
esac
exec /usr/bin/sha256sum "$@"
""",
            )
            old = install_root / "versions/old"
            executable(old / "bin/demo", "echo retained\n")
            (old / ".cybexos-release").write_text("old manifest\n")
            (install_root / "current").symlink_to("versions/old")
            (root / "bin/demo").symlink_to(install_root / "current/bin/demo")
            before = tree_snapshot(install_root)
            result = run(argv, env=env)
            assert not Path(env["MOCK_NETWORK_LOG"]).exists()
            assert not list(Path(env["TMPDIR"]).iterdir())
            if mutation.endswith("cache"):
                assert result.returncode == 0, (mutation, result.stdout, result.stderr)
                assert (install_root / "current/bin/demo").read_bytes() == Path(env["MOCK_DOWNLOAD"]).read_bytes()
            else:
                assert result.returncode == 75, (mutation, result.stdout, result.stderr)
                assert ("disappeared" if mutation == "delete-before-verify" else "changed before installation") in result.stderr
                assert "CHANGED:" not in result.stdout
                assert tree_snapshot(install_root) == before
                assert (root / "bin/demo").readlink() == install_root / "current/bin/demo"


def test_github_font_payload_and_post_commit_warning() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-github-font.") as temporary:
        root = Path(temporary)
        common = root / "common.sh"
        installer = root / "github-release-install"
        common_stub(common)
        render_installer(
            ROOT / "roles/apps/files/github-release-install", installer, root, common
        )
        env = github_environment(root)
        release = root / "release.json"
        env["MOCK_RELEASE_JSON"] = str(release)
        font_root = root / "fonts/demo-font"
        old = font_root / "versions/old"
        old.mkdir(parents=True)
        (old / "LICENSE.txt").write_text("license only\n")
        (font_root / "current").symlink_to("versions/old")

        cache = root / "cache/demo-font/v1"
        cache.mkdir(parents=True)
        asset = cache / "fonts.zip"
        make_zip(asset, {"LICENSE.txt": b"license only\n"})
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        manifest = f"tag=v1 checksum=sha256:{digest}"
        (old / ".cybexos-release").write_text(manifest + "\n")
        release_json(release, "v1", "fonts.zip", digest)
        argv = [
            str(installer),
            "demo-font",
            "owner/fonts",
            "^fonts[.]zip$",
            "font",
            "v1",
            f"sha256:{digest}",
        ]
        result = run(argv, env=env)
        assert result.returncode == 75
        assert "contains no supported font payload" in result.stderr
        assert (font_root / "current").resolve() == old

        make_zip(asset, {"LICENSE.txt": b"license\n", "Demo.ttf": b"font bytes\n"})
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        release_json(release, "v1", "fonts.zip", digest)
        argv[-1] = f"sha256:{digest}"
        result = run(argv, env=env)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "CHANGED: installed demo-font v1" in result.stdout
        assert (font_root / "current/Demo.ttf").is_file()

    with tempfile.TemporaryDirectory(prefix="cybexos-github-binary.") as temporary:
        root = Path(temporary)
        common = root / "common.sh"
        installer = root / "github-release-install"
        common_stub(common)
        render_installer(
            ROOT / "roles/apps/files/github-release-install", installer, root, common
        )
        env = github_environment(root)
        env["MOCK_PRUNE_FAIL"] = "1"
        release = root / "release.json"
        env["MOCK_RELEASE_JSON"] = str(release)
        payload = b"#!/usr/bin/env bash\necho demo\n"
        digest = hashlib.sha256(payload).hexdigest()
        release_json(release, "v2", "demo", digest)
        cache = root / "cache/demo/v2"
        cache.mkdir(parents=True)
        (cache / "demo").write_bytes(payload)
        result = run(
            [
                str(installer),
                "demo",
                "owner/repo",
                "^demo$",
                "binary",
                "v2",
                f"sha256:{digest}",
            ],
            env=env,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "CHANGED: installed demo v2" in result.stdout
        assert "could not prune older versions" in result.stderr
        assert (root / "apps/demo/current/bin/demo").is_file()

        Path(env["MOCK_API_LOG"]).unlink(missing_ok=True)
        env["MOCK_RELEASE_JSON"] = str(root / "offline.json")
        result = run(
            [
                str(installer),
                "demo",
                "owner/repo",
                "^demo$",
                "binary",
                "v2",
                f"sha256:{digest}",
            ],
            env=env,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == "UNCHANGED: demo v2"
        assert not Path(env["MOCK_API_LOG"]).exists()


def test_source_build_post_commit_warning() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-source-build.") as temporary:
        root = Path(temporary)
        common = root / "common.sh"
        installer = root / "source-app-build"
        common_stub(common)
        render_installer(ROOT / "roles/apps/files/source-app-build", installer, root, common)
        mock_bin = root / "mock-bin"
        mock_bin.mkdir()
        revision = "a" * 40
        executable(
            mock_bin / "git",
            r'''
if [[ -n ${MOCK_GIT_OFFLINE:-} ]]; then
  echo "unexpected git network call: $*" >&2
  exit 128
elif [[ $1 == ls-remote ]]; then
  printf '%s\trefs/tags/%s\n' "$MOCK_REVISION" "$MOCK_TAG"
elif [[ $1 == clone ]]; then
  mkdir -p "${@: -1}"
elif [[ $1 == -C ]]; then
  printf '%s\n' "$MOCK_REVISION"
else
  exit 2
fi
''',
        )
        executable(
            mock_bin / "podman",
            r'''
printf '%s\n' "$*" >> "$MOCK_PODMAN_LOG"
if [[ $1 == image && $2 == exists ]]; then
  [[ -f $MOCK_BUILDER_READY ]]
  exit
elif [[ $1 == image && $2 == inspect ]]; then
  if [[ ${MOCK_INSPECT_BARE_ID:-} == 1 ]]; then
    echo "${MOCK_BUILDER_ID#sha256:}"
  else
    echo "$MOCK_BUILDER_ID"
  fi
  exit
elif [[ $1 == pull ]]; then
  exit
elif [[ $1 == build ]]; then
  touch "$MOCK_BUILDER_READY"
  exit
fi
[[ $1 == run ]]
for argument in "$@"; do
  if [[ $argument == *:/out:Z ]]; then output=${argument%:/out:Z}; fi
done
mkdir -p "$output"
[[ " $* " == *" ${MOCK_BUILDER_ID#sha256:} bash "* ]]
printf 'rust\t0\t%s\t1.fc44\tx86_64\n' "${MOCK_RUST_VERSION:-1.90}" > "$output/packages.tsv"
for tool in rustc cargo gcc g++; do printf '%s %s\n' "$tool" "${MOCK_RUST_VERSION:-1.90}" > "$output/$tool.version"; done
[[ -z ${MOCK_METADATA_FAIL:-} ]] || rm "$output/rustc.version"
printf '#!/usr/bin/env bash\necho built\n' > "$output/$MOCK_BINARY"
chmod 0755 "$output/$MOCK_BINARY"
''',
        )
        env = {
            "PATH": f"{mock_bin}:/usr/bin:/bin",
            "MOCK_RELEASE_JSON": str(root / "unused.json"),
            "MOCK_API_LOG": str(root / "unused.log"),
            "MOCK_PRUNE_FAIL": "1",
            "MOCK_REVISION": revision,
            "MOCK_TAG": "v1",
            "MOCK_BINARY": "demo",
            "MOCK_PODMAN_LOG": str(root / "podman.log"),
            "MOCK_BUILDER_READY": str(root / "builder-ready"),
            "MOCK_BUILDER_ID": "sha256:" + "d" * 64,
        }
        old = root / "builds/demo/versions/old"
        (old / "bin").mkdir(parents=True)
        executable(old / "bin/demo", 'echo old\n')
        (root / "builds/demo/current").symlink_to("versions/old")
        (root / "bin").mkdir()
        (root / "bin/demo").symlink_to(root / "builds/demo/current/bin/demo")
        result = run(
            [
                str(installer),
                "demo",
                "https://example.invalid/demo.git",
                "demo",
                "v1",
                revision,
                "fedora@sha256:" + ("b" * 64),
            ],
            env=env,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "CHANGED: built demo v1" in result.stdout
        assert "could not prune older versions" in result.stderr
        assert "retained after update failure" not in result.stderr
        assert (root / "builds/demo/current/bin/demo").read_text().endswith("built\n")
        calls = Path(env["MOCK_PODMAN_LOG"]).read_text().splitlines()
        assert sum(call.startswith("build ") for call in calls) == 1, calls
        assert sum(call.startswith("pull ") for call in calls) == 1, calls
        assert any("CARGO_TARGET_DIR=/build-cache" in call and ":/root/.cargo/registry:z" in call
                   and ":/build-cache:Z" in call for call in calls), calls
        assert (root / "builds/demo/current/.cybexos-builder").read_text() == env["MOCK_BUILDER_ID"] + "\n"

        evidence = json.loads((root / "builds/demo/current/.cybexos-build-provenance.json").read_text())
        assert evidence["builder_image_id"] == env["MOCK_BUILDER_ID"]
        assert evidence["packages"][0]["version"] == "1.90"
        assert evidence["compilers"]["rustc"] == "rustc 1.90"
        assert evidence["binaries"]["demo"] == hashlib.sha256(
            (root / "builds/demo/current/bin/demo").read_bytes()).hexdigest()

        # The requested inputs describe the intact deployment;
        # the next converge must not contact the remote at all.
        result = run(
            [
                str(installer),
                "demo",
                "https://example.invalid/demo.git",
                "demo",
                "v1",
                revision,
                "fedora@sha256:" + ("b" * 64),
            ],
            env=dict(env, MOCK_GIT_OFFLINE="1"),
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == f"UNCHANGED: demo v1 ({revision})"
        assert Path(env["MOCK_PODMAN_LOG"]).read_text().splitlines() == calls
        # A different authorized source revision reuses the provisioned builder
        # and Cargo mounts; the deployed identity still changes atomically.
        next_revision = "c" * 40
        result = run([str(installer), "demo", "https://example.invalid/demo.git", "demo", "v2",
                      next_revision, "fedora@sha256:" + ("b" * 64)],
                     env=dict(env, MOCK_REVISION=next_revision, MOCK_TAG="v2"))
        assert result.returncode == 0, (result.stdout, result.stderr)
        calls = Path(env["MOCK_PODMAN_LOG"]).read_text().splitlines()
        assert sum(call.startswith("build ") for call in calls) == 1, calls
        assert sum(call.startswith("run ") for call in calls) == 2, calls
        warm = json.loads((root / "builds/demo/current/.cybexos-build-provenance.json").read_text())
        assert warm["builder_image_id"] == evidence["builder_image_id"]
        assert warm["packages"] == evidence["packages"]
        # A recreated derived image may resolve newer Fedora packages. Keep the
        # registry cache, isolate compiled objects by image ID, and report facts.
        Path(env["MOCK_BUILDER_READY"]).unlink()
        third = "e" * 40
        command = [str(installer), "demo", "https://example.invalid/demo.git", "demo", "v3",
                   third, "fedora@sha256:" + ("b" * 64)]
        changed_env = dict(env, MOCK_REVISION=third, MOCK_TAG="v3",
                           MOCK_BUILDER_ID="sha256:" + "f" * 64, MOCK_RUST_VERSION="1.91",
                           MOCK_INSPECT_BARE_ID="1")
        result = run(command, env=changed_env)
        assert result.returncode == 0, (result.stdout, result.stderr)
        changed = json.loads((root / "builds/demo/current/.cybexos-build-provenance.json").read_text())
        assert changed["builder_image_id"] != warm["builder_image_id"]
        assert changed["packages"][0]["version"] == "1.91"
        calls = Path(env["MOCK_PODMAN_LOG"]).read_text().splitlines()
        assert sum(call.startswith("build ") for call in calls) == 2, calls
        runs = [call for call in calls if call.startswith("run ")]
        def mounts(call):
            return next(part for part in call.split() if ":/build-cache:Z" in part)
        assert mounts(runs[0]) == mounts(runs[1])
        assert mounts(runs[1]) != mounts(runs[2])
        before = (root / "builds/demo/current").readlink()
        command[4:6] = ["v4", "1" * 40]
        result = run(command, env=dict(changed_env, MOCK_REVISION="1" * 40, MOCK_TAG="v4",
                                       MOCK_METADATA_FAIL="1"))
        assert result.returncode == 75, (result.stdout, result.stderr)
        assert (root / "builds/demo/current").readlink() == before
        assert json.loads((root / "builds/demo/current/.cybexos-build-provenance.json").read_text()) == changed
        assert not list((root / "builds/demo").glob(".build.*"))


def test_android_command_tools_rollback() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-android.") as temporary:
        root = Path(temporary)
        home = root / "home"
        sdk = home / "Android/Sdk"
        common = root / "common.sh"
        common_stub(common)
        template = (ROOT / "roles/apps/templates/android-sdk-update.j2").read_text()
        rendered = template.replace("{{ primary_home }}", str(home)).replace(
            "source /usr/local/libexec/cybexos-common.sh",
            f"source {shlex.quote(str(common))}",
        )
        installer = root / "android-sdk-update"
        executable(installer, rendered.removeprefix("#!/usr/bin/env bash\n"))

        old = sdk / "cmdline-tools/versions/old"
        executable(old / "bin/sdkmanager", "exit 0\n")
        (sdk / "cmdline-tools/current").symlink_to("versions/old")
        (sdk / "cmdline-tools/latest").symlink_to("current")
        (sdk / "cmdline-tools/.version").write_text("1.0.0\n")
        executable(sdk / "platform-tools/adb", "exit 0\n")
        (sdk / "platforms/android-44").mkdir(parents=True)
        (sdk / "platforms/android-44/android.jar").write_bytes(b"jar")
        executable(sdk / "build-tools/44.0.0/aapt2", "exit 0\n")

        archive = root / "tools.zip"
        sdkmanager = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ " $* " == *" --list_installed "* ]]; then exit 0; fi
            if [[ " $* " == *" --list "* ]]; then exit 42; fi
            exit 0
            """
        ).encode()
        make_zip(
            archive,
            {"cmdline-tools/bin/sdkmanager": sdkmanager},
            {"cmdline-tools/bin/sdkmanager"},
        )
        checksum = hashlib.sha1(archive.read_bytes()).hexdigest()
        metadata = root / "repository.xml"
        metadata.write_text(
            f"""<sdk-repository><remotePackage path="cmdline-tools;2.0">
            <revision><major>2</major><minor>0</minor><micro>0</micro></revision>
            <archives><archive><host-os>linux</host-os><complete>
            <url>tools.zip</url><checksum>{checksum}</checksum>
            </complete></archive></archives></remotePackage></sdk-repository>"""
        )
        mock_bin = root / "mock-bin"
        mock_bin.mkdir()
        executable(
            mock_bin / "curl",
            r'''
output=""
previous=""
for argument in "$@"; do
  if [[ $previous == -o || $previous == --output ]]; then output=$argument; fi
  previous=$argument
done
if [[ $output == *repository2-1.xml.new ]]; then
  /usr/bin/cp -- "$MOCK_ANDROID_METADATA" "$output"
else
  /usr/bin/cp -- "$MOCK_ANDROID_ARCHIVE" "$output"
fi
''',
        )
        env = {
            "HOME": str(home),
            "XDG_CACHE_HOME": str(root / "cache"),
            "PATH": f"{mock_bin}:/usr/bin:/bin",
            "MOCK_ANDROID_METADATA": str(metadata),
            "MOCK_ANDROID_ARCHIVE": str(archive),
            "MOCK_RELEASE_JSON": str(root / "unused.json"),
            "MOCK_API_LOG": str(root / "unused.log"),
        }
        result = run([str(installer)], env=env)
        assert result.returncode == 75, (result.stdout, result.stderr)
        assert (sdk / "cmdline-tools/current").readlink() == Path("versions/old")
        assert (sdk / "cmdline-tools/latest").readlink() == Path("current")
        assert (sdk / "cmdline-tools/.version").read_text() == "1.0.0\n"
        assert (sdk / "cmdline-tools/current/bin/sdkmanager").is_file()
        assert "Previous Android command-line tools restored" in result.stderr


def android_legacy_layout_fixture(*, fail_after_activation: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-android-legacy.") as temporary:
        root = Path(temporary)
        home = root / "home"
        sdk = home / "Android/Sdk"
        common = root / "common.sh"
        common_stub(common)
        template = (ROOT / "roles/apps/templates/android-sdk-update.j2").read_text()
        rendered = template.replace("{{ primary_home }}", str(home)).replace(
            "source /usr/local/libexec/cybexos-common.sh",
            f"source {shlex.quote(str(common))}",
        )
        installer = root / "android-sdk-update"
        executable(installer, rendered.removeprefix("#!/usr/bin/env bash\n"))

        version = "2.0.0"
        legacy = sdk / "cmdline-tools/latest"
        executable(legacy / "bin/sdkmanager", "exit 0\n")
        (legacy / "legacy-marker").write_bytes(b"legacy command tools\n")
        (sdk / "cmdline-tools/.version").write_text(f"{version}\n")
        executable(sdk / "platform-tools/adb", "exit 0\n")
        (sdk / "platforms/android-44").mkdir(parents=True)
        (sdk / "platforms/android-44/android.jar").write_bytes(b"jar")
        executable(sdk / "build-tools/44.0.0/aapt2", "exit 0\n")

        failure = "exit 42" if fail_after_activation else "exit 0"
        sdkmanager = textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            printf 'activated\n' > "$MOCK_ANDROID_ACTIVATION_LOG"
            if [[ " $* " == *" --list_installed "* ]]; then
              printf 'platform-tools\nplatforms;android-44\nbuild-tools;44.0.0\n'
              exit 0
            fi
            if [[ " $* " == *" --list "* ]]; then
              printf 'platforms;android-44 | 1\nbuild-tools;44.0.0 | 1\n'
              {failure}
            fi
            exit 0
            """
        ).encode()
        archive = root / "tools.zip"
        make_zip(
            archive,
            {"cmdline-tools/bin/sdkmanager": sdkmanager},
            {"cmdline-tools/bin/sdkmanager"},
        )
        checksum = hashlib.sha1(archive.read_bytes()).hexdigest()
        metadata = root / "repository.xml"
        metadata.write_text(
            f"""<sdk-repository><remotePackage path="cmdline-tools;{version}">
            <revision><major>2</major><minor>0</minor><micro>0</micro></revision>
            <archives><archive><host-os>linux</host-os><complete>
            <url>tools.zip</url><checksum>{checksum}</checksum>
            </complete></archive></archives></remotePackage></sdk-repository>"""
        )
        metadata_sha = hashlib.sha256(metadata.read_bytes()).hexdigest()
        (sdk / ".metadata-sha").write_text(f"{metadata_sha}\n")
        legacy_snapshot = tree_snapshot(sdk / "cmdline-tools")

        mock_bin = root / "mock-bin"
        mock_bin.mkdir()
        executable(
            mock_bin / "curl",
            r'''
output=""
previous=""
for argument in "$@"; do
  if [[ $previous == -o || $previous == --output ]]; then output=$argument; fi
  previous=$argument
done
if [[ $output == *repository2-1.xml.new ]]; then
  /usr/bin/cp -- "$MOCK_ANDROID_METADATA" "$output"
else
  /usr/bin/cp -- "$MOCK_ANDROID_ARCHIVE" "$output"
fi
''',
        )
        activation_log = root / "activation.log"
        env = {
            "HOME": str(home),
            "XDG_CACHE_HOME": str(root / "cache"),
            "PATH": f"{mock_bin}:/usr/bin:/bin",
            "MOCK_ANDROID_METADATA": str(metadata),
            "MOCK_ANDROID_ARCHIVE": str(archive),
            "MOCK_ANDROID_ACTIVATION_LOG": str(activation_log),
            "MOCK_RELEASE_JSON": str(root / "unused.json"),
            "MOCK_API_LOG": str(root / "unused.log"),
        }
        result = run([str(installer)], env=env)
        assert activation_log.read_text() == "activated\n", (result.stdout, result.stderr)

        if fail_after_activation:
            assert result.returncode == 75, (result.stdout, result.stderr)
            assert tree_snapshot(sdk / "cmdline-tools") == legacy_snapshot
            assert not (sdk / "cmdline-tools/current").exists()
            assert not (sdk / "cmdline-tools/versions").exists()
            assert (sdk / ".metadata-sha").read_text() == f"{metadata_sha}\n"
            assert "Previous Android command-line tools restored" in result.stderr
            assert "Existing complete Android SDK retained" in result.stderr
            assert "CHANGED:" not in result.stdout
        else:
            assert result.returncode == 0, (result.stdout, result.stderr)
            current = sdk / "cmdline-tools/current"
            latest = sdk / "cmdline-tools/latest"
            assert current.is_symlink()
            assert current.readlink() == Path(f"versions/{version}-{checksum[:12]}")
            assert latest.is_symlink() and latest.readlink() == Path("current")
            retained = list((sdk / "cmdline-tools/versions").glob("legacy-*"))
            assert len(retained) == 1
            assert (retained[0] / "legacy-marker").read_bytes() == b"legacy command tools\n"
            assert (sdk / ".metadata-sha").read_text() == f"{metadata_sha}\n"
            assert f"CHANGED: Android command-line tools {version}" in result.stdout


def test_android_same_version_legacy_layout_migration() -> None:
    android_legacy_layout_fixture(fail_after_activation=False)


def test_android_legacy_layout_rollback() -> None:
    android_legacy_layout_fixture(fail_after_activation=True)


def test_t3code_metadata_rollback() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-t3code.") as temporary:
        root = Path(temporary)
        home = root / "home"
        common = root / "common.sh"
        common_stub(common)
        installer = root / "t3code-update"
        rendered = (ROOT / "roles/dotfiles/templates/t3code-update.j2").read_text().replace(
            "source /usr/local/libexec/cybexos-common.sh",
            f"source {shlex.quote(str(common))}",
        )
        executable(installer, rendered.removeprefix("#!/usr/bin/env bash\n"))
        install_dir = home / ".local/share/t3code-nightly"
        install_dir.mkdir(parents=True)
        appimage = install_dir / "T3-Code-Nightly-x86_64.AppImage"
        executable(appimage, "echo old\n")
        old_payload = appimage.read_bytes()
        (install_dir / "version").write_text("old-nightly\n")
        (install_dir / "digest").write_text("old-digest\n")

        new_payload = root / "new.AppImage"
        new_payload.write_bytes(b"#!/usr/bin/env bash\necho new\n")
        digest = hashlib.sha256(new_payload.read_bytes()).hexdigest()
        release = root / "release.json"
        release.write_text(
            json.dumps(
                [
                    {
                        "tag_name": "v2-nightly.1",
                        "prerelease": True,
                        "assets": [
                            {
                                "name": "T3-Code-Nightly-x86_64.AppImage",
                                "browser_download_url": "https://example.invalid/t3",
                                "digest": f"sha256:{digest}",
                            }
                        ],
                    }
                ]
            )
        )
        mock_bin = root / "mock-bin"
        mock_bin.mkdir()
        executable(
            mock_bin / "curl",
            r'''
output=""
previous=""
for argument in "$@"; do
  if [[ $previous == --output ]]; then output=$argument; fi
  previous=$argument
done
/usr/bin/cp -- "$MOCK_T3_PAYLOAD" "$output"
''',
        )
        executable(
            mock_bin / "mv",
            r'''
destination=${@: -1}
if [[ $destination == "$MOCK_T3_FAIL_DEST" && ! -e $MOCK_T3_FAIL_ONCE ]]; then
  : > "$MOCK_T3_FAIL_ONCE"
  exit 86
fi
exec /usr/bin/mv "$@"
''',
        )
        env = {
            "HOME": str(home),
            "PATH": f"{mock_bin}:/usr/bin:/bin",
            "MOCK_RELEASE_JSON": str(release),
            "MOCK_API_LOG": str(root / "api.log"),
            "MOCK_T3_PAYLOAD": str(new_payload),
            "MOCK_T3_FAIL_DEST": str(install_dir / "digest"),
            "MOCK_T3_FAIL_ONCE": str(root / "failed-once"),
        }
        result = run([str(installer)], env=env)
        assert result.returncode == 75, (result.stdout, result.stderr)
        assert appimage.read_bytes() == old_payload
        assert (install_dir / "version").read_text() == "old-nightly\n"
        assert (install_dir / "digest").read_text() == "old-digest\n"
        assert "Previous T3Code nightly retained" in result.stderr
        assert "CHANGED:" not in result.stdout


def test_network_transfers_are_bounded() -> None:
    # A stalled mirror must not hold a synchronous Ansible task, or the durable
    # updater's lock, forever: every transfer goes through the bounded helper.
    common = ROOT / "roles/apps/files/cybexos-common.sh"
    with tempfile.TemporaryDirectory(prefix="cybexos-curl.") as temporary:
        root = Path(temporary)
        executable(root / "curl", 'printf "%s\\n" "$@" > "$MOCK_CURL_ARGS"\n')
        arguments = root / "arguments"
        result = run(
            ["bash", "-c", f"source {shlex.quote(str(common))}; cybexos_curl https://example.invalid"],
            env={"PATH": f"{root}:/usr/bin:/bin", "MOCK_CURL_ARGS": str(arguments)},
        )
        assert result.returncode == 0, result.stderr
        recorded = arguments.read_text().splitlines()
        for flag in ("--connect-timeout", "--speed-limit", "--speed-time", "--retry"):
            assert flag in recorded, flag
    for relative in (
        "roles/apps/files/github-release-install",
        "roles/apps/templates/android-sdk-update.j2",
        "roles/dotfiles/templates/t3code-update.j2",
    ):
        source = (ROOT / relative).read_text()
        assert "\ncurl " not in source and " curl --fail" not in source, relative
    source_build = (ROOT / "roles/apps/files/source-app-build").read_text()
    assert "GIT_HTTP_LOW_SPEED_LIMIT" in source_build
    assert "timeout 120 git ls-remote" in source_build


def test_font_archive_checksum_contract() -> None:
    tasks = (ROOT / "roles/apps/tasks/upstream.yml").read_text()
    health = tasks.index("Inspect checksum-addressed pinned font extractions")
    reset = tasks.index("Remove stale pinned font extraction trees")
    extract = tasks.index("Install pinned fonts with their bundled license notices")
    verify = tasks.index("Verify pinned font archives contain their expected font")
    record = tasks.index("Record checksum-addressed pinned font extraction state")
    assert health < reset < extract < verify < record
    health_block = tasks[health:reset]
    assert "test -f {{ apps_pinned_font_archive_marker | quote }} &&" in health_block
    assert "test -f {{ apps_pinned_font_archive_payload | quote }}" in health_block
    assert "apps_pinned_font_archive_marker:" in health_block
    assert "apps_pinned_font_archive_payload:" in health_block
    assert "item.version\n      ~" not in health_block
    assert ".cybexos-archive-{{ item.checksum | regex_replace('^sha256:', '') }}" in tasks
    assert 'creates: "/usr/local/share/fonts/{{ item.name }}/{{ item.version }}/{{ item.expected_font }}"' not in tasks


if __name__ == "__main__":
    test_prune_count()
    test_github_rpm_convergence_and_tag_endpoint()
    test_github_verified_cache_kinds_without_network()
    test_github_cache_misses_and_unsafe_paths()
    test_github_cache_miss_download_and_rpm_identity()
    test_github_cache_snapshot_and_final_verification()
    test_github_font_payload_and_post_commit_warning()
    test_source_build_post_commit_warning()
    test_android_command_tools_rollback()
    test_android_same_version_legacy_layout_migration()
    test_android_legacy_layout_rollback()
    test_t3code_metadata_rollback()
    test_network_transfers_are_bounded()
    test_font_archive_checksum_contract()
    print("PASS  installer convergence and rollback fixtures")

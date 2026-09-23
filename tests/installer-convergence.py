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
  if [[ ${2:-} == --qf ]]; then printf '%s' "$MOCK_NEVRA"; fi
  exit 0
fi
if [[ $1 == -qp && ${2:-} == --qf ]]; then
  if [[ $3 == '%{NAME}' ]]; then printf '%s' "$MOCK_PACKAGE";
  else printf '%s' "$MOCK_NEVRA"; fi
  exit 0
fi
exit 2
''',
    )
    executable(mock_bin / "dnf", 'printf "%s\\n" "$*" >> "$MOCK_DNF_LOG"\n')
    executable(mock_bin / "curl", 'echo "unexpected curl invocation" >&2; exit 99\n')
    return {
        "PATH": f"{mock_bin}:/usr/bin:/bin",
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
        assert (state / "version").read_text().strip() == (
            f"tag=v1 checksum=sha256:{digest}"
        )
        assert (state / "nevra").read_text().strip() == env["MOCK_NEVRA"]
        assert Path(env["MOCK_API_LOG"]).read_text().strip().endswith(
            "/releases/tags/v1"
        )
        assert "releases?per_page=" not in (
            ROOT / "roles/apps/files/github-release-install"
        ).read_text()

        # The authorized tag and checksum already describe the intact package,
        # so convergence makes no GitHub round trip and survives being offline.
        Path(env["MOCK_DNF_LOG"]).write_text("")
        Path(env["MOCK_API_LOG"]).unlink()
        offline = dict(env, MOCK_RELEASE_JSON=str(root / "offline.json"))
        result = run(argv, env=offline)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == "UNCHANGED: demo v1"
        assert Path(env["MOCK_DNF_LOG"]).read_text() == ""
        assert not Path(env["MOCK_API_LOG"]).exists()

        # Whenever the package must be (re)installed, the pin must still agree
        # with GitHub's digest.
        (state / "version").unlink()
        release_json(release, "v1", "demo.rpm", "f" * 64)
        result = run(argv, env=env)
        assert result.returncode == 75
        assert "disagrees with GitHub's release digest" in result.stderr
        assert Path(env["MOCK_DNF_LOG"]).read_text() == ""


def make_zip(path: Path, files: dict[str, bytes], executable_names: set[str] | None = None) -> None:
    executable_names = executable_names or set()
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in files.items():
            info = zipfile.ZipInfo(name)
            mode = 0o100755 if name in executable_names else 0o100644
            info.external_attr = mode << 16
            archive.writestr(info, payload)


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

        Path(env["MOCK_API_LOG"]).unlink()
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
for argument in "$@"; do
  if [[ $argument == *:/out:Z ]]; then output=${argument%:/out:Z}; fi
done
mkdir -p "$output"
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

        # The authorized commit, image, and recipe describe the intact build;
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
    test_github_font_payload_and_post_commit_warning()
    test_source_build_post_commit_warning()
    test_android_command_tools_rollback()
    test_android_same_version_legacy_layout_migration()
    test_android_legacy_layout_rollback()
    test_t3code_metadata_rollback()
    test_network_transfers_are_bounded()
    test_font_archive_checksum_contract()
    print("PASS  installer convergence and rollback fixtures")

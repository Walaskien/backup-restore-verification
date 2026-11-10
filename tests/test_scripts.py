"""Tests for the parts of the scripts that do not need Docker."""

import os
import shlex
import subprocess
import time
from pathlib import Path

import pytest
from prometheus_client.parser import text_string_to_metric_families

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"


def run_lib(code, env=None):
    """Run a bit of bash with lib.sh sourced, strict mode like the real scripts."""
    full_env = {**os.environ, **(env or {})}
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail; . {SCRIPTS}/lib.sh; {code}"],
        capture_output=True,
        text=True,
        env=full_env,
    )


def run_script(name, args=(), env=None):
    full_env = {**os.environ, **(env or {})}
    return subprocess.run(
        [str(SCRIPTS / name), *args], capture_output=True, text=True, env=full_env
    )


def read_prom(path):
    samples = {}
    for family in text_string_to_metric_families(Path(path).read_text()):
        for s in family.samples:
            samples[s.name] = s.value
    return samples


def make_backup(directory, stamp, age_days=0, db="appdb"):
    directory.mkdir(parents=True, exist_ok=True)
    base = directory / f"{db}_{stamp}"
    dump = Path(f"{base}.dump")
    dump.write_bytes(b"not a real dump " + stamp.encode())
    Path(f"{dump}.sha256").write_text("x  y\n")
    Path(f"{base}.manifest").write_text("public.t 1 abc\n")
    old = time.time() - age_days * 86400
    for p in (dump, Path(f"{dump}.sha256"), Path(f"{base}.manifest")):
        os.utime(p, (old, old))
    return dump


def test_write_prom_is_complete_and_readable_by_others(tmp_path):
    target = tmp_path / "m" / "backup.prom"
    r = run_lib(
        f'{{ gauge a_metric "some help" 5; gauge b_metric "other" 7; }} | write_prom {target}'
    )
    assert r.returncode == 0, r.stderr
    assert read_prom(target) == {"a_metric": 5, "b_metric": 7}
    assert target.stat().st_mode & 0o777 == 0o644
    assert [p.name for p in target.parent.iterdir()] == ["backup.prom"]


def test_prom_prev_gives_old_value_or_fallback(tmp_path):
    prom = tmp_path / "x.prom"
    prom.write_text("# HELP foo h\n# TYPE foo gauge\nfoo 42\nbar 1\n")
    assert run_lib(f"prom_prev {prom} foo 0").stdout == "42"
    assert run_lib(f"prom_prev {prom} missing 9").stdout == "9"
    assert run_lib(f"prom_prev {tmp_path}/nope.prom foo 3").stdout == "3"


@pytest.mark.parametrize(
    "sidecar, expected",
    [
        ("good", 0),
        ("deadbeef  f.dump\n", 1),
        (None, 2),
    ],
)
def test_checksum_ok(tmp_path, sidecar, expected):
    dump = tmp_path / "f.dump"
    dump.write_bytes(b"hello")
    if sidecar == "good":
        digest = run_lib(f"sha256_of {dump}").stdout.strip()
        assert len(digest) == 64
        (tmp_path / "f.dump.sha256").write_text(f"{digest}  f.dump\n")
    elif sidecar:
        (tmp_path / "f.dump.sha256").write_text(sidecar)
    r = run_lib(f"rc=0; checksum_ok {dump} || rc=$?; echo $rc")
    assert r.stdout.strip() == str(expected)


def test_latest_backup_ignores_partial_files_and_other_names(tmp_path):
    make_backup(tmp_path, "20261101T020000Z")
    newest = make_backup(tmp_path, "20261103T020000Z")
    (tmp_path / "appdb_20261104T020000Z.dump.partial").write_text("x")
    make_backup(tmp_path, "20261105T020000Z", db="otherdb")
    assert run_lib(f"latest_backup {tmp_path}").stdout.strip() == str(newest)
    assert run_lib(f"latest_backup {tmp_path}/missing").stdout == ""


def test_rotation_never_touches_the_newest_min_keep(tmp_path):
    stamps = [f"2026100{i}T020000Z" for i in range(1, 7)]
    for s in stamps:
        make_backup(tmp_path, s, age_days=30)
    r = run_lib(f"rotate_backups {tmp_path} 7 3")
    assert r.returncode == 0, r.stderr
    left = sorted(p.name for p in tmp_path.glob("*.dump"))
    assert left == [f"appdb_{s}.dump" for s in stamps[3:]]
    # sidecars go together with their dump
    assert len(list(tmp_path.iterdir())) == 3 * 3


def test_rotation_keeps_recent_files_beyond_min_keep(tmp_path):
    for i in range(1, 6):
        make_backup(tmp_path, f"2026110{i}T020000Z", age_days=5 - i)
    run_lib(f"rotate_backups {tmp_path} 7 2")
    assert len(list(tmp_path.glob("*.dump"))) == 5


def test_rotation_drops_only_old_ones_between(tmp_path):
    make_backup(tmp_path, "20261001T020000Z", age_days=20)
    make_backup(tmp_path, "20261020T020000Z", age_days=8)
    make_backup(tmp_path, "20261105T020000Z", age_days=2)
    make_backup(tmp_path, "20261109T020000Z", age_days=1)
    run_lib(f"rotate_backups {tmp_path} 7 2")
    left = sorted(p.name for p in tmp_path.glob("*.dump"))
    assert left == ["appdb_20261105T020000Z.dump", "appdb_20261109T020000Z.dump"]


def test_rotation_cleans_abandoned_work_dirs_only_when_old(tmp_path):
    old, fresh = tmp_path / ".work.old", tmp_path / ".work.fresh"
    old.mkdir()
    fresh.mkdir()
    two_days_ago = time.time() - 2 * 86400
    os.utime(old, (two_days_ago, two_days_ago))
    run_lib(f"rotate_backups {tmp_path} 7 3")
    assert not old.exists()
    assert fresh.exists()


@pytest.mark.parametrize("name", ["public.orders", "orders", "s1.t_2"])
def test_valid_table_names(name):
    assert run_lib(f"valid_table {name}").returncode == 0


@pytest.mark.parametrize("name", ["", "orders; drop table x", "a b", "t$1", "'x'"])
def test_invalid_table_names(name):
    assert run_lib(f"valid_table {shlex.quote(name)}").returncode == 1


def test_quote_table():
    assert run_lib("quote_table public.orders").stdout == '"public"."orders"'


def prepare_dirs(tmp_path):
    return {
        "BACKUP_DIR": str(tmp_path / "primary"),
        "SECONDARY_DIR": str(tmp_path / "secondary"),
        "METRICS_DIR": str(tmp_path / "metrics"),
    }


def test_verify_without_any_backup_fails_and_keeps_last_success(tmp_path):
    env = prepare_dirs(tmp_path)
    (tmp_path / "metrics").mkdir()
    (tmp_path / "metrics" / "restore_verification.prom").write_text(
        "restore_verification_last_success_timestamp_seconds 12345\n"
    )
    r = run_script("verify-restore.sh", env=env)
    assert r.returncode == 10, r.stderr
    m = read_prom(tmp_path / "metrics" / "restore_verification.prom")
    assert m["restore_verification_success"] == 0
    assert m["restore_verification_last_success_timestamp_seconds"] == 12345


def test_verify_stops_on_checksum_mismatch_before_touching_docker(tmp_path):
    env = prepare_dirs(tmp_path)
    make_backup(tmp_path / "primary", "20261101T020000Z")  # sidecar holds a bogus hash
    r = run_script("verify-restore.sh", env=env)
    assert r.returncode == 11
    assert "checksum mismatch" in r.stderr
    m = read_prom(tmp_path / "metrics" / "restore_verification.prom")
    assert m["restore_verification_success"] == 0
    assert m["restore_verification_last_success_timestamp_seconds"] == 0


def test_verify_notices_missing_manifest(tmp_path):
    env = prepare_dirs(tmp_path)
    dump = make_backup(tmp_path / "primary", "20261101T020000Z")
    digest = run_lib(f"sha256_of {dump}").stdout.strip()
    Path(f"{dump}.sha256").write_text(f"{digest}  {dump.name}\n")
    Path(str(dump).replace(".dump", ".manifest")).unlink()
    r = run_script("verify-restore.sh", env=env)
    assert r.returncode == 11
    assert "manifest is missing" in r.stderr


def test_verify_notices_missing_second_copy(tmp_path):
    env = prepare_dirs(tmp_path)
    dump = make_backup(tmp_path / "primary", "20261101T020000Z")
    digest = run_lib(f"sha256_of {dump}").stdout.strip()
    Path(f"{dump}.sha256").write_text(f"{digest}  {dump.name}\n")
    (tmp_path / "secondary").mkdir()
    r = run_script("verify-restore.sh", env=env)
    assert r.returncode == 14
    assert "is missing" in r.stderr


def test_backup_with_unknown_container_fails_and_keeps_old_success(tmp_path):
    env = {**prepare_dirs(tmp_path), "PG_CONTAINER": "brv-no-such-container"}
    (tmp_path / "metrics").mkdir()
    (tmp_path / "metrics" / "backup.prom").write_text(
        "backup_last_success_timestamp_seconds 1700000000\nbackup_size_bytes 999\n"
    )
    r = run_script("backup.sh", env=env)
    assert r.returncode == 10
    m = read_prom(tmp_path / "metrics" / "backup.prom")
    assert m["backup_last_run_success"] == 0
    assert m["backup_last_success_timestamp_seconds"] == 1700000000
    assert m["backup_size_bytes"] == 999

#!/usr/bin/env python3
"""Black-box contract tests for the shell source-policy gate.

Invokes the repository invariant script in explicit-path mode against
minimal temporary fixtures. Production scope is any explicit ``.lua``
path; test scope is an explicit path containing a ``/tests/`` segment.
Hook cases run the real pre-commit entrypoint with a ``scripts/lint.sh``
double, proving the hook defers to the lint gate. Staged-index cases run
the real lint gate with formatter/type doubles, so they stay independent
of those binaries while proving lint sees the staged index.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "check-invariants.sh"
REPO_ROOT = SCRIPT.parents[2]
HOOK_SOURCE = REPO_ROOT / "scripts" / "hooks" / "pre-commit"
LUARC_SOURCE = REPO_ROOT / ".luarc.json"
LINT_SOURCE = REPO_ROOT / "scripts" / "lint.sh"
SCOPE_SOURCE = REPO_ROOT / "scripts" / "lib" / "scope.sh"
REPO_CHECK_SOURCE = REPO_ROOT / "scripts" / "lib" / "check-repository.sh"

# Fixed core modules the invariant gate must always account for.
REQUIRED_CORE_FILES = (
    "libs/nds/src/nitro/g3d/Nsbmd.lua",
    "romdump/src/digest/model/MaterialCompiler.lua",
    "romdump/src/digest/model/MeshCompiler.lua",
    "libs/nds/src/love/GxRenderer.lua",
    "libs/nds/src/love/shaders/map.glsl",
)

CLEAN_LUA_STUB = "--- Module stub.\nlocal stub = {}\nreturn stub\n"
CLEAN_SHADER_STUB = "// Shader stub.\n"

CLEAN_PRODUCTION_BODY = (
    "--- Module stub.\n"
    "---@param value string\n"
    "local function compute(value)\n"
    "  return value\n"
    "end\n"
    "return compute\n"
)

PRODUCTION_ANY_BODY = (
    "--- Module stub.\n"
    "---@param value any\n"
    "local function compute(value)\n"
    "  return value\n"
    "end\n"
    "return compute\n"
)

REFERENCE_ANY_BODY = (
    "--- Reference stub.\n"
    "---@param value any\n"
    "local function compute(value)\n"
    "  return value\n"
    "end\n"
    "return compute\n"
)

REFERENCE_DIRECTIVE_BODY = (
    "local value = {}\n"
    "---@diagnostic disable-next-line: unused-local\n"
    "value.compute(nil)\n"
    "return value\n"
)

INVALID_LUARC_BODY = '{"diagnostics": {"disable": ["duplicate-set-field"], "enable": false}}\n'


def run_gate(path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), str(path)],
        check=False,
        capture_output=True,
        text=True,
    )


def write_production(directory: Path, name: str, body: str) -> Path:
    target = directory / "prod" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    return target


def write_test(directory: Path, name: str, body: str) -> Path:
    target = directory / "tests" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    return target


class ShellPolicyTest(unittest.TestCase):
    """Production annotation and diagnostic-directive policy."""

    def test_production_param_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "param_any.lua",
                "--- Module stub.\n"
                "---@param value any\n"
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("any", result.stderr.lower())

    def test_production_generic_function_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "generic_any.lua",
                "--- Module stub.\n"
                "---@type fun<T>(value: any): T\n"
                "local handler = {}\n"
                "return handler\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_inline_assertion_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "assertion_any.lua",
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "local outcome = compute(1) --[[@as any]]\n"
                "return outcome\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_annotation_prose_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "prose_any.lua",
                "--- Module stub.\n"
                "---@param mode string -- select any mode\n"
                "local function compute(mode)\n"
                "  return mode\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_runtime_identifier_any_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "runtime_any.lua",
                "local function compute()\n"
                "  return 1\n"
                "end\n"
                "local any = compute()\n"
                "return any\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_shaped_table_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "shaped_table.lua",
                "--- Module stub.\n"
                "---@type table<string, unknown>\n"
                "local mapping = {}\n"
                "return mapping\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_bare_table_param_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "bare_table.lua",
                "--- Module stub.\n"
                "---@param value table\n"
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("table", result.stderr.lower())

    def test_production_bare_table_return_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "bare_return.lua",
                "--- Module stub.\n"
                "---@return table\n"
                "local function compute()\n"
                "  return {}\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_next_line_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "directive.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_narrow_test_directive_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "narrow_test.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_test_file_wide_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "wide_test.lua",
                "local value = {}\n"
                "---@diagnostic disable: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_test_other_category_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "other_category_test.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: unused-local\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_standalone_type_table_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "standalone_type_table.lua",
                "--- Module stub.\n"
                "---@type table\n"
                "local mapping = {}\n"
                "return mapping\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("table", result.stderr.lower())

    def test_production_trailing_type_table_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "trailing_type_table.lua",
                "local mapping = {} ---@type table\n"
                "return mapping\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_inline_as_table_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "inline_as_table.lua",
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "local outcome = compute(1) --[[@as table]]\n"
                "return outcome\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)


def _run_git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )


def _run_hook(repo: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "scripts/hooks/pre-commit"],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )


def _init_repo(
    root: Path,
    fixtures: dict[str, str],
    *,
    with_lint_stub: bool = True,
) -> Path:
    """Create an isolated Git repo wiring the current hook and checker.

    Copies the repository's current hook and invariant checker into a fresh
    temporary repository alongside a valid ``.luarc.json``, the fixed core
    modules, and the given Lua fixtures, then commits a clean baseline. The
    hook under test is never installed, so the baseline commit cannot invoke
    it. When ``with_lint_stub`` holds, a ``scripts/lint.sh`` double
    accepting ``--check`` with exit zero stands in for the fast lint gate;
    the hook requires that collaborator, so hook success cases must keep the
    stub while the missing-lint case proves the dependency is real.
    """
    _run_git(root, "init", "-q")
    _run_git(root, "config", "user.email", "gate-test@example.com")
    _run_git(root, "config", "user.name", "gate test")
    _run_git(root, "config", "commit.gpgsign", "false")
    checker_target = root / "scripts" / "lib" / "check-invariants.sh"
    checker_target.parent.mkdir(parents=True, exist_ok=True)
    checker_target.write_bytes(SCRIPT.read_bytes())
    checker_target.chmod(0o755)
    hook_target = root / "scripts" / "hooks" / "pre-commit"
    hook_target.parent.mkdir(parents=True, exist_ok=True)
    hook_target.write_bytes(HOOK_SOURCE.read_bytes())
    hook_target.chmod(0o755)
    if with_lint_stub:
        lint_stub = root / "scripts" / "lint.sh"
        lint_stub.write_text(
            "#!/usr/bin/env bash\n"
            "# Test double for the fast lint gate.\n"
            "set -euo pipefail\n"
            'if [ "${1:-}" != "--check" ]; then\n'
            '  echo "expected --check" >&2\n'
            "  exit 2\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        lint_stub.chmod(0o755)
    (root / ".luarc.json").write_bytes(LUARC_SOURCE.read_bytes())
    for relative in REQUIRED_CORE_FILES:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            CLEAN_SHADER_STUB if relative.endswith(".glsl") else CLEAN_LUA_STUB,
            encoding="utf-8",
        )
    for relative, body in fixtures.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body, encoding="utf-8")
    _run_git(root, "add", "-A")
    _run_git(root, "commit", "-qm", "clean baseline")
    return root


def _stage(repo: Path, relative: str, body: str) -> None:
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    _run_git(repo, "add", "--", relative)


class HookDelegationTest(unittest.TestCase):
    """The pre-commit hook defers to the lint gate."""

    def test_hook_fails_without_lint_present(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = _init_repo(
                Path(directory),
                {"app/src/sample.lua": CLEAN_PRODUCTION_BODY},
                with_lint_stub=False,
            )
            self.assertFalse((repo / "scripts/lint.sh").exists())
            _stage(
                repo,
                "app/src/sample.lua",
                CLEAN_PRODUCTION_BODY + "--- Staged note.\n",
            )
            result = _run_hook(repo)
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_failing_lint_blocks_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = _init_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _stage(
                repo,
                "app/src/sample.lua",
                CLEAN_PRODUCTION_BODY + "--- Staged note.\n",
            )
            lint_stub = repo / "scripts" / "lint.sh"
            lint_stub.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\nexit 1\n",
                encoding="utf-8",
            )
            lint_stub.chmod(0o755)
            result = _run_hook(repo)
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_passing_lint_allows_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = _init_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _stage(
                repo,
                "app/src/sample.lua",
                CLEAN_PRODUCTION_BODY + "--- Staged note.\n",
            )
            result = _run_hook(repo)
            self.assertEqual(result.returncode, 0, result.stderr)


def _init_lint_repo(root: Path, fixtures: dict[str, str]) -> tuple[Path, Path]:
    """Isolated repo wiring the real lint gate with stubbed binaries.

    Installs the repository's current ``lint.sh`` and its ``scripts/lib``
    collaborators into a fresh repo, then provides ``stylua`` and
    ``lua-language-server`` doubles that always succeed, so the lint
    outcome is decided by the invariant checks alone.
    """
    _init_repo(root, fixtures, with_lint_stub=False)
    lint_target = root / "scripts" / "lint.sh"
    lint_target.write_bytes(LINT_SOURCE.read_bytes())
    lint_target.chmod(0o755)
    lib = root / "scripts" / "lib"
    for source in (SCOPE_SOURCE, REPO_CHECK_SOURCE):
        target = lib / source.name
        target.write_bytes(source.read_bytes())
        target.chmod(0o755)
    bin_dir = root / "test-bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name in ("stylua", "lua-language-server"):
        stub = bin_dir / name
        stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        stub.chmod(0o755)
    return root, bin_dir


def _run_lint(repo: Path, bin_dir: Path) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    return subprocess.run(
        ["bash", "scripts/lint.sh", "--check"],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


class LintStagedGateTest(unittest.TestCase):
    """lint.sh must see the staged index, not just the worktree."""

    def test_lint_rejects_staged_violation_with_clean_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _stage(repo, "app/src/sample.lua", PRODUCTION_ANY_BODY)
            (repo / "app/src/sample.lua").write_text(
                CLEAN_PRODUCTION_BODY, encoding="utf-8"
            )
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertNotEqual(result.returncode, 0, combined)
            self.assertIn("app/src/sample.lua", combined)

    def test_lint_passes_clean_staged_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _stage(
                repo,
                "app/src/sample.lua",
                CLEAN_PRODUCTION_BODY + "--- Staged note.\n",
            )
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertEqual(result.returncode, 0, combined)

    def test_lint_rejects_dirty_worktree_with_clean_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _stage(
                repo,
                "app/src/sample.lua",
                CLEAN_PRODUCTION_BODY + "--- Staged note.\n",
            )
            (repo / "app/src/sample.lua").write_text(
                PRODUCTION_ANY_BODY, encoding="utf-8"
            )
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertNotEqual(result.returncode, 0, combined)
            self.assertIn("app/src/sample.lua", combined)

    def test_reference_annotation_debt_without_directive_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"data/scripts/example.lua": CLEAN_LUA_STUB}
            )
            _stage(repo, "data/scripts/example.lua", REFERENCE_ANY_BODY)
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertEqual(result.returncode, 0, combined)

    def test_reference_and_tooling_directives_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory),
                {
                    "data/scripts/example.lua": CLEAN_LUA_STUB,
                    "tools/example.lua": CLEAN_LUA_STUB,
                },
            )
            _stage(repo, "data/scripts/example.lua", REFERENCE_DIRECTIVE_BODY)
            _stage(repo, "tools/example.lua", REFERENCE_DIRECTIVE_BODY)
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertNotEqual(result.returncode, 0, combined)
            self.assertIn("data/scripts/example.lua", combined)
            self.assertIn("tools/example.lua", combined)

    def test_lint_rejects_staged_luarc_violation_with_clean_worktree(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            valid_luarc = (repo / ".luarc.json").read_bytes()
            _stage(repo, ".luarc.json", INVALID_LUARC_BODY)
            (repo / ".luarc.json").write_bytes(valid_luarc)
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertNotEqual(result.returncode, 0, combined)
            self.assertIn(".luarc.json", combined)

    def test_lint_rejects_missing_luarc(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, bin_dir = _init_lint_repo(
                Path(directory), {"app/src/sample.lua": CLEAN_PRODUCTION_BODY}
            )
            _run_git(repo, "rm", "-q", ".luarc.json")
            result = _run_lint(repo, bin_dir)
            combined = result.stderr + result.stdout
            self.assertNotEqual(result.returncode, 0, combined)
            self.assertIn(".luarc.json", combined)


if __name__ == "__main__":
    unittest.main()

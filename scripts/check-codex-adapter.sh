#!/usr/bin/env bash
# check-codex-adapter.sh — deterministic checks for the Codex adapter surface.
#
# Codex support here is repo skill discovery (.agents/skills symlink) plus
# `$story-setup` project deployment (.codex/agents + .codex/hooks). There is no
# materialized plugin package; agent TOMLs are generated from the Claude agent
# templates by scripts/generate-codex-agents.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "required file missing: $1"; }
assert_path() { [ -e "$1" ] || fail "required path missing: $1"; }
assert_grep() { grep -Eq "$1" "$2" || fail "$3 ($2)"; }

cd "$REPO_ROOT"

echo "Codex adapter check"
echo "==================="
echo "Repo: $REPO_ROOT"

CODEX_DIR="skills/story-setup/references/codex"
assert_path ".agents/skills"
assert_file "$CODEX_DIR/AGENTS.md.tmpl"
assert_file "$CODEX_DIR/hooks/hooks.json"
assert_file "$CODEX_DIR/hooks/story_codex_hook.py"
assert_path "$CODEX_DIR/agents"
assert_file "scripts/generate-codex-agents.py"

python3 -m json.tool "$CODEX_DIR/hooks/hooks.json" >/dev/null
python3 - <<'PY'
from pathlib import Path
for name in (
    'scripts/generate-codex-agents.py',
    'skills/story-setup/references/codex/hooks/story_codex_hook.py',
):
    compile(Path(name).read_text(encoding='utf-8'), name, 'exec')
PY

echo "  OK JSON/Python syntax"

# Windows encoding safety (issue #164 class): the hook carries Chinese 正文/细纲 over
# stdin/stdout, so it must use UTF-8 bytes, not Windows' ANSI code page text streams.
HOOK_PY="$CODEX_DIR/hooks/story_codex_hook.py"
assert_grep 'sys\.stdin\.buffer\.read' "$HOOK_PY" "Codex hook must read stdin as UTF-8 bytes"
assert_grep 'sys\.stdout\.buffer\.write' "$HOOK_PY" "Codex hook must write stdout as UTF-8 bytes"
if grep -qE 'sys\.stdin\.read\(\)|sys\.stdout\.write\(' "$HOOK_PY"; then
  fail "Codex hook must not use text-mode sys.stdin.read()/sys.stdout.write() (Windows ANSI hazard)"
fi
if grep -nE '\.read_text\(\)' "$HOOK_PY"; then
  fail "Codex hook read_text() must pass encoding='utf-8' (Windows ANSI hazard)"
fi

echo "  OK Windows encoding safety (UTF-8 stdio + file reads)"

# Repo skill discovery: .agents/skills is a symlink to skills/, so Codex sees the
# single canonical copy (no second materialized skill tree).
skill_count="$(find skills -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
[ "$skill_count" = "13" ] || fail "expected 13 skills, found $skill_count"
for skill in skills/*/SKILL.md; do
  name="$(basename "$(dirname "$skill")")"
  assert_file ".agents/skills/$name/SKILL.md"
done

echo "  OK .agents/skills discovery symlink ($skill_count skills)"

# Custom-agent TOMLs are generated deterministically from the Claude templates.
python3 scripts/generate-codex-agents.py --dest "$TMP_DIR/agents" >/dev/null
diff -qr "$TMP_DIR/agents" "$CODEX_DIR/agents" >/dev/null \
  || fail "generated Codex agents are stale; run scripts/generate-codex-agents.py"

python3 - <<'PY'
import tomllib
from pathlib import Path
expected = {
    'chapter-extractor', 'character-designer', 'consistency-checker',
    'narrative-writer', 'story-architect', 'story-explorer', 'story-researcher',
}
read_only = {'chapter-extractor', 'consistency-checker', 'story-explorer'}
found = set()
for path in sorted(Path('skills/story-setup/references/codex/agents').glob('*.toml')):
    data = tomllib.loads(path.read_text())
    for key in ('name', 'description', 'developer_instructions'):
        assert data.get(key), f'{path}: missing {key}'
    name = data['name']
    instructions = data['developer_instructions']
    assert path.name == f'{name}.toml', f'{path}: filename/name mismatch'
    assert '.codex/skills/story-setup/references/agent-references/' in instructions
    assert 'agent_type' in instructions, f'{path}: missing Codex agent_type guidance'
    assert 'subagent_type' not in instructions, f'{path}: leaked Claude subagent_type wording'
    assert 'unknown agent_type' in instructions, f'{path}: missing runtime fallback guidance'
    if name in read_only:
        assert data.get('sandbox_mode') == 'read-only', f'{path}: expected read-only sandbox'
    found.add(name)
assert found == expected, found
PY

echo "  OK Codex custom-agent TOML (schema + generator determinism)"

# Deployment hooks target the project .codex/ and must not require git to launch.
assert_grep 'for PYBIN in python3 python py' "$CODEX_DIR/hooks/hooks.json" "deployment hooks must probe Python interpreter"
assert_grep 'CODEX_PROJECT_DIR.*CLAUDE_PROJECT_DIR.*SEARCH_DIR' "$CODEX_DIR/hooks/hooks.json" "deployment hooks must resolve project root without requiring git"
if grep -q 'git rev-parse' "$CODEX_DIR/hooks/hooks.json"; then
  fail "deployment hooks must not require git to launch story_codex_hook.py"
fi
assert_grep '\.codex/hooks/story_codex_hook\.py' "$CODEX_DIR/hooks/hooks.json" "deployment hooks must point at project .codex/hooks"

assert_grep '\$story-setup|\$story-long-write|/skills' "$CODEX_DIR/AGENTS.md.tmpl" "Codex AGENTS template must mention skill invocation"
assert_grep '\.codex/agents/\*\.toml' "$CODEX_DIR/AGENTS.md.tmpl" "Codex AGENTS template must mention custom agent location"
assert_grep '\.codex/hooks\.json' "$CODEX_DIR/AGENTS.md.tmpl" "Codex AGENTS template must mention hooks location"
assert_grep 'references/codex' skills/story-setup/SKILL.md "story-setup must document Codex references"
assert_grep 'target_cli:.*codex|codex.*target_cli' skills/story-setup/SKILL.md "story-setup must document codex target_cli"
assert_grep '\.codex/agents|\.codex/hooks\.json' skills/story-review/SKILL.md "story-review must check Codex agents"

echo "  OK Codex docs/instruction anchors"
echo ""
echo "OK: Codex adapter checks passed"

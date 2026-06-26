#!/usr/bin/env bash
# test-codex-hooks.sh — synthetic Codex hook contract tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HOOK_SRC="$REPO_ROOT/skills/story-setup/references/codex/hooks/story_codex_hook.py"
ROOT="$TMP_DIR/story-project"
HOOK="$ROOT/.codex/hooks/story_codex_hook.py"
mkdir -p "$ROOT/.codex/hooks"
cp "$HOOK_SRC" "$HOOK"
chmod +x "$HOOK"

git -C "$ROOT" init -q
git -C "$ROOT" config user.email codex-hook@example.invalid
git -C "$ROOT" config user.name codex-hook-test

run_hook() {
  local event="$1" payload="$2"
  (cd "$ROOT" && printf '%s' "$payload" | CODEX_PROJECT_DIR="$ROOT" python3 "$HOOK" "$event")
}

# Read the hook's stdout as UTF-8 bytes (not locale-decoded text): the hook emits
# UTF-8 Chinese deny reasons, and Windows Python defaults stdin to the ANSI code page,
# which would raise UnicodeDecodeError here even when the hook output is correct.
assert_json() {
  python3 -c 'import json,sys; json.loads(sys.stdin.buffer.read().decode("utf-8"))' >/dev/null
}

assert_denied() {
  local out="$1" label="$2"
  printf '%s' "$out" | assert_json || fail "$label did not emit valid JSON: $out"
  printf '%s' "$out" | python3 -c 'import json,sys; o=json.loads(sys.stdin.buffer.read().decode("utf-8")); h=o.get("hookSpecificOutput",{}); assert h.get("hookEventName")=="PreToolUse" and h.get("permissionDecision")=="deny" and h.get("permissionDecisionReason")' || fail "$label was not denied: $out"
}

assert_additional_context() {
  local out="$1" label="$2"
  printf '%s' "$out" | assert_json || fail "$label did not emit valid JSON: $out"
  printf '%s' "$out" | python3 -c 'import json,sys; o=json.loads(sys.stdin.buffer.read().decode("utf-8")); h=o.get("hookSpecificOutput",{}); assert h.get("additionalContext")' || fail "$label missing additionalContext: $out"
}

assert_empty() {
  local out="$1" label="$2"
  [ -z "$out" ] || fail "$label expected empty allow output, got: $out"
}

echo "Codex hook synthetic tests"
echo "=========================="
echo "Fixture: $ROOT"

mkdir -p "$ROOT/book/正文" "$ROOT/book/大纲" "$ROOT/book/设定"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"cat > book/正文/第001章_开端.md <<EOF\n正文\nEOF"}}')"
assert_denied "$out" "long prose without outline"
: > "$ROOT/book/大纲/细纲_第1章.md"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"cat > book/正文/第001章_开端.md <<EOF\n正文\nEOF"}}')"
assert_empty "$out" "long prose with outline"

out="$(run_hook pre-tool-prose-guard '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: book/正文/第002章_新局.md\n+正文\n*** End Patch\n"}}')"
assert_denied "$out" "apply_patch long prose without outline"
: > "$ROOT/book/正文/第009章_已存在.md"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Write","tool_input":{"file_path":"book/正文/第009章_已存在.md","content":"改稿"}}')"
assert_empty "$out" "existing prose rewrite"

mkdir -p "$ROOT/short"
: > "$ROOT/short/设定.md"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Write","tool_input":{"file_path":"short/正文.md","content":"正文"}}')"
assert_denied "$out" "short prose without outline"
: > "$ROOT/short/小节大纲.md"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Write","tool_input":{"file_path":"short/正文.md","content":"正文"}}')"
assert_empty "$out" "short prose with outline"

mkdir -p "$ROOT/impbook/正文" "$ROOT/拆文库/impbook"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Write","tool_input":{"file_path":"impbook/正文/第1章_导入.md","content":"正文"}}')"
assert_empty "$out" "story-import long migration"

echo "  OK outline-before-prose guard"

# A Bash command that only MENTIONS a prose path (grep / echo arg / doc) must not be treated
# as a write target; only real write ops (redirection / tee / touch / cp|mv dest) count.
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"grep -n book/正文/第7章.md notes.md"}}')"
assert_empty "$out" "command merely mentioning prose path is not denied"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"echo book/正文/第7章.md >> changelog.md"}}')"
assert_empty "$out" "prose path as echo arg before non-prose redirect is not denied"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"echo x | tee book/正文/第7章_x.md"}}')"
assert_denied "$out" "tee write to prose without outline is still denied"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"touch book/正文/第7章_x.md"}}')"
assert_denied "$out" "touch write to prose without outline is denied"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"cp draft.md book/正文/第7章_x.md"}}')"
assert_denied "$out" "cp write to prose without outline is denied"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"cp draft.md book/正文/第7章_x.md 2>/dev/null"}}')"
assert_denied "$out" "cp write with trailing redirect is denied (dest still parsed)"
out="$(run_hook pre-tool-prose-guard '{"tool_name":"Bash","tool_input":{"command":"cp book/正文/第1章.md backup.md"}}')"
assert_empty "$out" "cp FROM a prose file (source, not dest) is not denied"

echo "  OK prose command-scan precision"

cat > "$ROOT/book/正文/第1章.md" <<'TXT'
年龄：18
TXT
cat > "$ROOT/short/正文.md" <<'TXT'
身高: 180
TXT
git -C "$ROOT" add book/正文/第1章.md short/正文.md
out="$(run_hook pre-tool-commit-advisory '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}')"
assert_additional_context "$out" "commit advisory"
echo "$out" | grep -q 'Hardcoded character attributes' || fail "commit advisory did not inspect staged markdown"
echo "$out" | grep -q 'short/正文.md' || fail "commit advisory missed short prose"
out="$(run_hook pre-tool-commit-advisory '{"tool_name":"Bash","tool_input":{"command":"echo git commit docs"}}')"
assert_empty "$out" "non-commit bash command"

echo "  OK commit advisory"

mkdir -p "$ROOT/book/追踪"
cat > "$ROOT/.story-deployed" <<'TXT'
deployed_at: 2026-06-25T00:00:00Z
agents_version: 14
setup_skill_version: 1.2.3
target_cli: codex
resolver_strategy: project-local-skill-reference
references_dir: .codex/skills/story-setup/references/agent-references
TXT
printf 'book\n' > "$ROOT/.active-book"
printf '# 上下文\n' > "$ROOT/book/追踪/上下文.md"
out="$(run_hook session-start '{"hook_event_name":"SessionStart"}')"
assert_additional_context "$out" "session-start context"
echo "$out" | grep -q 'Active book' || fail "session-start did not mention active book"
out="$(run_hook pre-compact '{"hook_event_name":"PreCompact"}')"
printf '%s' "$out" | assert_json || fail "pre-compact invalid JSON: $out"
echo "$out" | grep -q 'Story Compact Summary' || fail "pre-compact missing summary"
out="$(run_hook post-compact '{"hook_event_name":"PostCompact"}')"
printf '%s' "$out" | assert_json || fail "post-compact invalid JSON: $out"
out="$(run_hook stop '{"hook_event_name":"Stop"}')"
printf '%s' "$out" | assert_json || fail "stop invalid JSON: $out"

echo "  OK session/compact/stop JSON"

nested="$ROOT/nested/a/b"
mkdir -p "$nested"
out="$(cd "$TMP_DIR" && printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"book/正文/第003章_嵌套.md","content":"正文"}}' "$nested" | python3 "$HOOK" pre-tool-prose-guard)"
assert_denied "$out" "cwd-based root resolution"

echo "  OK cwd-based root resolution"

# __file__ self-location (the Windows-critical resolver) on ALL platforms: with a bogus
# CODEX_PROJECT_DIR (env skipped) and an unrelated cwd, the hook must resolve root from its own
# .codex/hooks/ location. Discriminating: 细纲 exists at the true root, so a wrong root → deny;
# only __file__-derived root → allow. (The valid-env tests above let env win and never hit this.)
: > "$ROOT/book/大纲/细纲_第8章.md"
out="$(cd "$TMP_DIR" && CODEX_PROJECT_DIR="$TMP_DIR/does-not-exist" python3 "$HOOK" pre-tool-prose-guard <<'JSON'
{"tool_name":"Write","tool_input":{"file_path":"book/正文/第8章_x.md","content":"x"}}
JSON
)"
assert_empty "$out" "__file__ self-location resolves root when env is bogus and cwd unrelated"
rm -f "$ROOT/book/大纲/细纲_第8章.md"

echo "  OK __file__ self-location (all platforms)"

NON_GIT="$TMP_DIR/non-git-story-project"
NON_GIT_HOOK="$NON_GIT/.codex/hooks/story_codex_hook.py"
mkdir -p "$NON_GIT/.codex/hooks" "$NON_GIT/book/正文" "$NON_GIT/book/大纲" "$NON_GIT/nested/a/b"
cp "$HOOK_SRC" "$NON_GIT_HOOK"
cp "$REPO_ROOT/skills/story-setup/references/codex/hooks/hooks.json" "$NON_GIT/.codex/hooks.json"
launcher_cmd="$(
  NON_GIT="$NON_GIT" python3 - <<'PY'
import json, os
from pathlib import Path
hooks = json.loads((Path(os.environ["NON_GIT"]) / ".codex/hooks.json").read_text(encoding="utf-8"))
print(hooks["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)"
out="$(
  cd "$NON_GIT/nested/a/b"
  printf '{"tool_name":"Write","tool_input":{"file_path":"book/正文/第004章_非Git.md","content":"正文"}}' | eval "$launcher_cmd"
)"
assert_denied "$out" "non-git deployment launcher root search"

echo "  OK non-git deployment launcher root search"

# Root propagation: non-git project, outline PRESENT at the true root, triggered from a nested
# cwd → must ALLOW. The launcher resolves the root in shell; it must reach the Python hook
# (via CODEX_PROJECT_DIR and/or the hook self-locating from __file__) instead of Python falling
# back to the nested cwd and wrongly denying. This case also exercises Windows (Git Bash MSYS
# path passed to native Python), which is exactly where naive env/cwd propagation breaks.
: > "$NON_GIT/book/大纲/细纲_第4章.md"
out="$(cd "$NON_GIT/nested/a/b"; unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR; printf '{"tool_name":"Write","tool_input":{"file_path":"book/正文/第004章_非Git.md","content":"正文"}}' | eval "$launcher_cmd")"
assert_empty "$out" "non-git nested cwd + outline present allows (root reaches Python hook)"
rm -f "$NON_GIT/book/大纲/细纲_第4章.md"

echo "  OK non-git nested root propagation"

# Missing deployment: a cwd whose ancestors have no .codex/hooks/story_codex_hook.py → the
# launcher must no-op (exit 0) silently, NOT run "//.codex/hooks/story_codex_hook.py" (which
# happens if it treats "/" as the project root after an exhausted upward search).
NO_DEPLOY="$TMP_DIR/no-deploy/x/y"
mkdir -p "$NO_DEPLOY"
out="$(cd "$NO_DEPLOY"; unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR; printf '{"tool_name":"Write","tool_input":{"file_path":"book/正文/第1章.md","content":"正文"}}' | eval "$launcher_cmd" 2>&1)"
assert_empty "$out" "missing deployment launcher no-ops silently"
case "$out" in *//.codex*) fail "launcher executed //.codex/... on missing deployment: $out";; esac

echo "  OK missing-deployment launcher no-op"
echo ""
echo "OK: Codex hook synthetic tests passed"

#!/bin/bash
# test-ai-patterns.sh — regression tests for the deterministic AI-pattern detector.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi

SCRIPT="$REPO_ROOT/skills/story-deslop/scripts/check-ai-patterns.js"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FIXTURE="$TMP_DIR/fixture.md"
OUT="$TMP_DIR/out.json"

cat > "$FIXTURE" <<'EOF'
---
title: 不是A，而是B
---
是不是这里不该报。
他不是冷漠，而是绝望。
她不是害怕，是累了。
他不是笨是太急。
他不是冷漠；是绝望。
它不是普通的粥！
是药。
她不是不想走，也不是不敢走。
他不是讨厌你，只是累了。
他不是走了，可是没人知道。
他不是不愿意，于是答应了。
她不是生气，倒是有点担心。
他不是哭就是闹。
这事不是真的就是假的。
这不是你的东西，是吗？
他不是傻子。是吗？
他不是傻子，是吧。
不是这样，是嘛。
```
他不是冷漠，而是绝望。
```
~~~md
他不是普通表达，而是代码示例。
~~~
EOF

set +e
node "$SCRIPT" --json "$FIXTURE" > "$OUT"
status=$?
set -e

if [ "$status" -ne 1 ]; then
  echo "FAIL: expected detector to exit 1 for positive findings, got $status" >&2
  cat "$OUT" >&2 || true
  exit 1
fi

node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const excerpts = report.findings.map((finding) => finding.excerpt);

// Genuine flips that MUST be detected: 而是 / “，是” / compact / “；是” / hard-stop + 是.
const expected = [
  '不是冷漠，而是绝望',
  '不是害怕，是累了',
  '不是笨是太急',
  '不是冷漠；是绝望',
  '不是普通的粥！ 是药',
];

// Natural prose that MUST NOT be flagged: the trailing 是 of a conjunction
// (只是/可是/于是/倒是…) after a separator is not a positive copula (issue #166
// false-positive class). “是不是”/“也不是” second-negation must also stay silent.
const forbidden = [
  '只是累了',
  '可是没人知道',
  '于是答应了',
  '倒是有点担心',
  // either-or「不是A就是B / 也是B」与句尾反问「…，是吗 / 是吧 / 是嘛」不是否定后翻转。
  '哭就是',
  '真的就是',
  '是吗',
  '是吧',
  '是嘛',
];

if (report.findings.length !== expected.length) {
  throw new Error(`expected ${expected.length} findings, got ${report.findings.length}: ${JSON.stringify(excerpts)}`);
}

for (const excerpt of expected) {
  if (!excerpts.includes(excerpt)) {
    throw new Error(`missing expected excerpt: ${excerpt}; got ${JSON.stringify(excerpts)}`);
  }
}

for (const marker of forbidden) {
  if (excerpts.some((excerpt) => excerpt.includes(marker))) {
    throw new Error(`false positive: conjunction "${marker}" was flagged; got ${JSON.stringify(excerpts)}`);
  }
}
NODE

echo "AI pattern detector regression tests passed."

# --- 段落级检测：碎句号 / 长段落 / 破折号（issue #188） ---
FIXTURE2="$TMP_DIR/fixture-prose.md"
LONG_PARA="他沿着长廊一直往里走，"
i=0
while [ "$i" -lt 16 ]; do
  LONG_PARA="${LONG_PARA}走过一道又一道紧闭的木门，"
  i=$((i + 1))
done
LONG_PARA="${LONG_PARA}终于在尽头停下，盯着那点暗红看了很久。"
{
  # 6 句连续短叙述句 → 碎句号
  printf '%s\n' '他站起来。' '他走过去。' '门开了。' '风进来。' '他停住。' '心一沉。'
  # 6 句对话短句 → 必须不报碎句号（成片短句是对话/弹幕的正常形态）
  printf '%s\n' '“这真的没问题。”' '“一点也不难。”' '“我信你。”' '“你别紧张。”' '“好。”' '“嗯。”'
  # 破折号 → em-dash（按功能改写，不机械替换）
  printf '%s\n' '她借着月光看清了桌上那张纸的边角——那是一张旧纸。'
  # 单段超长 → long-paragraph
  printf '%s\n' "$LONG_PARA"
} > "$FIXTURE2"

set +e
node "$SCRIPT" --json "$FIXTURE2" > "$OUT"
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "FAIL: expected prose detector to exit 1 for positive findings, got $status" >&2
  cat "$OUT" >&2 || true
  exit 1
fi

node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const counts = report.findings.reduce((m, f) => ((m[f.type] = (m[f.type] || 0) + 1), m), {});

// Exactly one of each new prose type, nothing else. The 6 dialogue lines must NOT
// trip 碎句号 (成片短句是对话/弹幕的正常形态 — only narrative runs count).
if (report.findings.length !== 3) {
  throw new Error(`expected 3 prose findings, got ${report.findings.length}: ${JSON.stringify(report.findings.map((f) => `${f.type}@${f.line}`))}`);
}
for (const type of ['period-stutter', 'em-dash', 'long-paragraph']) {
  if (counts[type] !== 1) throw new Error(`expected exactly 1 ${type}, got ${counts[type] || 0}`);
}
// 碎句号 must flag the narrative block (line 1), not the dialogue cluster (lines 7-12).
const stutter = report.findings.find((f) => f.type === 'period-stutter');
if (stutter.line !== 1) {
  throw new Error(`period-stutter should start at the narrative block (line 1), got line ${stutter.line}`);
}
NODE

echo "Prose pattern (碎句号/长段落/破折号) regression tests passed."

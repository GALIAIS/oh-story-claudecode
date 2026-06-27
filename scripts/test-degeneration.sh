#!/bin/bash
# test-degeneration.sh — regression tests for the model-degeneration detector.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi

SCRIPT="$REPO_ROOT/skills/story-deslop/scripts/check-degeneration.js"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

POS="$TMP_DIR/degen-positive.md"
NEG="$TMP_DIR/degen-negative.md"
OUT="$TMP_DIR/out.json"

# Positive: 紧邻整行复读 + 长句复读3次 + AI自指 + 括号省略占位符 + 末尾截断。
cat > "$POS" <<'EOF'
他握紧了拳头，慢慢站起身来，眼里全是不甘。
他握紧了拳头，慢慢站起身来，眼里全是不甘。
她看着窗外那场下了整夜的大雨，心里空落落的。
过了一会儿。
她看着窗外那场下了整夜的大雨，心里空落落的。
又过了一会儿。
她看着窗外那场下了整夜的大雨，心里空落落的。
作为一个AI语言模型，我无法继续生成这段内容。
（此处省略五百字）
他转过身，慢慢地走向门口，手还在
EOF

# Negative: 通俗网文体裁内的「正常重复」必须不报——弹幕道歉刷屏、短句排比、对话复沓。
cat > "$NEG" <<'EOF'
他站在原地，看着那条消息，久久没有动。
“对不起。”
“对不起。”
“对不起。”
我等你。我等你。我等你。
风很大，吹得人睁不开眼。
作为一个人工智能时代的产物，他对孤独习以为常。
“作为人工智能，我会一直陪着你。”
这一刻，他终于明白了什么叫做释怀。
EOF

set +e
node "$SCRIPT" --json "$POS" > "$OUT"
pos_status=$?
set -e
if [ "$pos_status" -ne 1 ]; then
  echo "FAIL: expected degeneration detector to exit 1 on positive fixture, got $pos_status" >&2
  cat "$OUT" >&2 || true
  exit 1
fi

node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const counts = report.findings.reduce((m, f) => ((m[f.type] = (m[f.type] || 0) + 1), m), {});
const want = { 'verbatim-repeat': 2, 'placeholder-leak': 2, 'truncated': 1 };
if (report.findings.length !== 5) {
  throw new Error(`expected 5 positive findings, got ${report.findings.length}: ${JSON.stringify(report.findings.map((f) => `${f.type}@${f.line}`))}`);
}
for (const [type, n] of Object.entries(want)) {
  if (counts[type] !== n) throw new Error(`expected ${n} ${type}, got ${counts[type] || 0}`);
}
NODE

# Negative fixture must be clean (exit 0). 通俗网文 的排比/复沓/弹幕刷屏不是退化。
set +e
neg_out="$(node "$SCRIPT" "$NEG" 2>&1)"
neg_status=$?
set -e
if [ "$neg_status" -ne 0 ]; then
  echo "FAIL: degeneration detector false-positive on legit 重复/排比/弹幕 prose (exit $neg_status):" >&2
  echo "$neg_out" >&2
  exit 1
fi

# --- 工程词泄漏 meta-leak（issue #173 comment 4814607240）---
META_POS="$TMP_DIR/meta-positive.md"
META_NEG="$TMP_DIR/meta-negative.md"

# 正例：纯工程词(细纲/情节点) + 章节结构词(本章/下一章，含对话里的) + 系统标签词(任务描述)。
cat > "$META_POS" <<'EOF'
## 第5章 真相
他握紧了拳头，慢慢站起身来。
本章他终于发现了真相。
“该到下一章了。”他低声说。
按照细纲，他应该先去找她。
这个情节点其实早就埋下了。
任务描述：保护好那个女孩。
EOF
set +e
node "$SCRIPT" --json "$META_POS" > "$OUT"
set -e
node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const meta = report.findings.filter((f) => f.type === 'meta-leak');
if (meta.length !== 5) {
  throw new Error(`expected 5 meta-leak findings (本章/下一章/细纲/情节点/任务描述), got ${meta.length}: ${JSON.stringify(meta.map((f) => f.excerpt))}`);
}
NODE

# 负例：标题行「第N章 章名」(无 ## 前缀) 必须不算工程词泄漏；正常正文 0 命中。
cat > "$META_NEG" <<'EOF'
第1章 军宣新星
他站在台上，看着台下黑压压的人群。
风很大，吹得旗子猎猎作响。
他握紧了话筒，深吸一口气。
EOF
set +e
meta_neg_out="$(node "$SCRIPT" "$META_NEG" 2>&1)"
meta_neg_status=$?
set -e
if [ "$meta_neg_status" -ne 0 ]; then
  echo "FAIL: meta-leak false-positive on chapter title line / clean prose (exit $meta_neg_status):" >&2
  echo "$meta_neg_out" >&2
  exit 1
fi

echo "Degeneration detector regression tests passed."

#!/bin/zsh
# 增量备份所有 Claude Code 转录 (.jsonl),对抗已知 bug #49903(转录被静默删除)。
# 关键:NOT --delete —— 源文件被 bug 删掉后,备份里仍保留,这样才能恢复。
# 目的地默认在 ~/.claude 之外(改 LEADER_BACKUP_DIR 可指到 iCloud/外盘)。
SRC="$HOME/.claude/projects/"
DEST="${LEADER_BACKUP_DIR:-$HOME/claude-transcript-backups}"
LOG=/tmp/leader-transcript-backup.log
mkdir -p "$DEST"
/usr/bin/rsync -a --prune-empty-dirs \
  --include='*/' --include='*.jsonl' --exclude='*' \
  "$SRC" "$DEST/" 2>>"$LOG"
n=$(find "$DEST" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
sz=$(du -sh "$DEST" 2>/dev/null | cut -f1)
echo "$(date '+%Y-%m-%d %H:%M:%S')  synced -> $DEST  ($n jsonl, $sz)" >> "$LOG"

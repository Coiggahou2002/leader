#!/bin/zsh
# 启动(或重启)Leader 常驻 GUI,并在浏览器打开。
# 用法:  ~/.claude/skills/leader/start.sh
PORT=8799
DIR="$(cd "$(dirname "$0")" && pwd)"
lsof -ti :$PORT 2>/dev/null | xargs kill 2>/dev/null
nohup python3 "$DIR/server.py" > /tmp/leader-server.log 2>&1 &
disown
sleep 1
echo "Leader GUI → http://127.0.0.1:$PORT (日志: /tmp/leader-server.log)"
open "http://127.0.0.1:$PORT"

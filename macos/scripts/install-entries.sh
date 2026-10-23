#!/bin/bash
source "$(dirname "$0")/env.sh"
cat > "$PROJECT/启动.command" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
open "$ROOT/artifacts/FusionPlay Mac.app"
EOF
cat > "$PROJECT/停止.command" <<'EOF'
#!/bin/bash
osascript -e 'tell application id "tech.zrim.fusionplay.mac" to quit'
EOF
cat > "$PROJECT/清理.command" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
/usr/bin/python3 "$ROOT/source/macos/scripts/cleanup.py" --execute
read -r -p "按回车关闭窗口…"
EOF
chmod 700 "$PROJECT/启动.command" "$PROJECT/停止.command" "$PROJECT/清理.command"

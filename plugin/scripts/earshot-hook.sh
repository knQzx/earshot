#!/bin/sh
has_direct_hooks() {
    for f in "$@"; do
        [ -f "$f" ] || continue
        if grep -o '/[^"\\]*/Contents/MacOS/earshot-hook' "$f" 2>/dev/null | { while IFS= read -r path; do [ -x "$path" ] && exit 0; done; exit 1; }; then
            return 0
        fi
    done
    return 1
}

config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
project="${CLAUDE_PROJECT_DIR:-}"
for app in "$HOME/Applications/Earshot.app" "/Applications/Earshot.app"; do
    hook="$app/Contents/MacOS/earshot-hook"
    [ -x "$hook" ] || continue
    if has_direct_hooks "$config/settings.json" ${project:+"$project/.claude/settings.json"} ${project:+"$project/.claude/settings.local.json"}; then
        cat >/dev/null
        exit 0
    fi
    exec "$hook"
done
cat >/dev/null
exit 0

# Earshot plugin for Claude Code

Connects Claude Code to [Earshot](https://github.com/knQzx/earshot), a small macOS app that lives in the MacBook notch. With the plugin enabled, every session shows up in the notch, permission requests can be answered there, and your Earshot policy rules (for example "ask me before every git push") apply to Claude's commands.

The plugin only forwards Claude Code hook events to the app on your Mac. It has no network code. If Earshot is not installed in `~/Applications` or `/Applications`, it does nothing.

Install the app first (see the main README), then in Claude Code:

```
/plugin install earshot --marketplace knQzx/earshot
```

Unofficial. Not affiliated with or endorsed by Anthropic.

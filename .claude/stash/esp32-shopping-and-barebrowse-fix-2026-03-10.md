# Stash: ESP32 Shopping + Barebrowse URL Fix
**Date:** 2026-03-10

## Active Work

### ESP32 Shopping List
Finding Tier 1 components from one website. User's cart on bitsandparts.nl has 4/5 items:

| Item | Price | Status |
|------|-------|--------|
| ESP32-S3 DevKitC N16R8 | €15,95 | In cart |
| Breadboard 400 pins MB102 | €2,95 | In cart |
| Jumper wires Dupont 10cm F/M 40x | €1,40 | In cart |
| INMP441 MEMS I2S Mic | €3,75 | In cart |
| **2.8" ILI9341 TFT display** | — | **NOT FOUND on bitsandparts** |

**Blocker:** Bitsandparts doesn't carry a cheap 2.8" ILI9341 TFT. Options presented:
- A: Get 1.8" TFT from bitsandparts (€6,95) — smaller but functional
- B: Get display from Elecrow ($7.50) separately
- C: Find all on AliExpress (cheapest, slow shipping)

User hasn't chosen yet — session was stashed at this decision point.

### Doc updated
`/home/hamr/Documents/PycharmProjects/wearehere/store-assets/next-project-ideas.md` — ESP32 section rewritten with tiered shopping list, project ideas table. User chose TFT over OLED (wants wider display, less pixelated text).

## Completed: Barebrowse URL Fix

### Problem
Snapshot URL prefix (`# <url>`) was invisible to agents because Claude Code's MCP client strips lines starting with `#`.

### Fix (two rounds)
1. **v0.4.7** — Changed `connect().snapshot()` prefix from `# url` to `url: url` in `src/index.js:226,229`
2. **v0.4.8** — Also fixed `browse()` one-shot function at `src/index.js:106` (missed in 0.4.7). Updated MCP server version string.

### Root cause of slow rollout
- Old global install (`npm install -g barebrowse@0.2.2`) at `/usr/local/bin/barebrowse` was shadowing npx resolution
- Removed with `pkexec npm uninstall -g barebrowse`
- npx cache dirs at `~/.npm/_npx/` also needed clearing

### Both versions published to npm and pushed to GitHub.

## Barebrowse MCP Config
Currently using npx (published npm): `npx barebrowse mcp` (scope: user)
Alternative suggested but not applied: point to local dev version at `/home/hamr/PycharmProjects/barebrowse/cli.js mcp`

## Key Decisions
- User prefers TFT display over OLED (text readability)
- User prefers white OLED over blue/yellow split (if OLED were chosen)
- ESP32-S3-DevKitC-1 N16R8 confirmed as the board (16MB flash, 8MB PSRAM variant)
- Breadboard is required — board pin headers plug directly into it
- Skip mega kits, buy modular

#!/usr/bin/env bash
# career-ops cloud bootstrap
#
# Brings a fresh Claude Code cloud container to a working career-ops install.
# The container is ephemeral: it is re-cloned on every session, so this script
# is the thing that makes a session reproducible.
#
#   ./cloud-setup.sh                 # full setup
#   DATA_REPO=<git-url> ./cloud-setup.sh
#
# Safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_REPO="${DATA_REPO:-https://github.com/yoniseast-oss/career-ops-data.git}"
DATA_DIR="${DATA_DIR:-$(dirname "$REPO_DIR")/career-ops-data}"

# Build an empty-but-valid user layer so a session still works before the
# private data repo exists. Only fills in what is missing — never clobbers
# real data on a re-run.
scaffold_data_root() {
  mkdir -p "$DATA_DIR"/{config,data,reports,output,jds,interview-prep,documents,writing-samples,modes}
  for d in data reports output jds interview-prep documents writing-samples; do
    touch "$DATA_DIR/$d/.gitkeep"
  done
  [ -f "$DATA_DIR/config/profile.yml" ] || \
    cp "$REPO_DIR/config/profile.example.yml" "$DATA_DIR/config/profile.yml"
  [ -f "$DATA_DIR/portals.yml" ] || \
    cp "$REPO_DIR/templates/portals.example.yml" "$DATA_DIR/portals.yml"
  [ -f "$DATA_DIR/data/applications.md" ] || printf '%s\n' \
    '# Applications Tracker' '' \
    '| # | Date | Company | Role | Score | Status | PDF | Report | Notes |' \
    '|---|------|---------|------|-------|--------|-----|--------|-------|' \
    > "$DATA_DIR/data/applications.md"
  # doctor.mjs auto-copies modes/_profile.md, _custom.md, _brief.md and
  # voice-dna.md from their templates on first run, so they are not seeded here.
}

echo "==> 1/4 Installing dependencies"
# The postinstall hook runs `playwright install chromium`, which this
# environment's network policy blocks. The image already ships Chromium, so
# skip the download and repair the version mismatch in step 2 instead.
cd "$REPO_DIR"
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --ignore-scripts --no-audit --no-fund

echo "==> 2/4 Reconciling Playwright with the pre-installed browser"
# package.json pins an exact Playwright whose expected Chromium build rarely
# matches the one baked into the image. Rather than hardcode build numbers,
# ask Playwright where it expects the binary, then point that path at whatever
# build is actually present. Self-healing across image and dependency bumps.
node - <<'NODE'
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');

const root = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';

// Find a real Chromium binary in the image, preferring the headless shell.
function findBinary() {
  const found = [];
  for (const dir of fs.existsSync(root) ? fs.readdirSync(root) : []) {
    for (const rel of [
      'chrome-linux/headless_shell',
      'chrome-headless-shell-linux64/chrome-headless-shell',
      'chrome-linux/chrome',
    ]) {
      const p = path.join(root, dir, rel);
      if (fs.existsSync(p) && !fs.lstatSync(p).isSymbolicLink()) found.push(p);
    }
  }
  return found.sort((a, b) => b.includes('headless') - a.includes('headless'))[0];
}

(async () => {
  try {
    const b = await chromium.launch();
    await b.close();
    console.log('    Chromium launches as-is — nothing to repair.');
    return;
  } catch (err) {
    const want = /Executable doesn't exist at (\S+)/.exec(err.message)?.[1];
    const have = findBinary();
    if (!want || !have) {
      console.log(`    Could not auto-repair Chromium: ${err.message.split('\n')[0]}`);
      process.exit(0); // non-fatal: only PDF generation needs a browser
    }
    fs.mkdirSync(path.dirname(want), { recursive: true });
    fs.rmSync(want, { force: true });
    fs.symlinkSync(have, want);
    console.log(`    Linked ${want}\n         -> ${have}`);
    const b = await chromium.launch();
    await b.close();
    console.log('    Chromium verified.');
  }
})().catch((e) => {
  console.log(`    Chromium still unavailable: ${e.message.split('\n')[0]}`);
});
NODE

echo "==> 3/4 Syncing private data root"
if [ -d "$DATA_DIR/.git" ]; then
  git -C "$DATA_DIR" pull --ff-only origin HEAD 2>/dev/null \
    && echo "    Pulled latest into $DATA_DIR" \
    || echo "    Kept existing $DATA_DIR (no fast-forward available)"
elif git clone -q "$DATA_REPO" "$DATA_DIR" 2>/dev/null; then
  echo "    Cloned $DATA_REPO -> $DATA_DIR"
else
  echo "    Could not clone $DATA_REPO — scaffolding a local data root instead."
  echo "    Create the repo (private) and push \$DATA_DIR, or set DATA_REPO=<url>."
  scaffold_data_root
fi

# The marker makes every career-ops script resolve the user layer out of the
# private repo instead of this public checkout. Relative, so it survives a
# clone to a different absolute path.
printf '%s\n' "../$(basename "$DATA_DIR")" > "$REPO_DIR/.career-ops-data"

echo "==> 4/4 Health check"
cd "$REPO_DIR"
node doctor.mjs || true
echo
echo "Data root: $DATA_DIR"
echo "Setup complete."

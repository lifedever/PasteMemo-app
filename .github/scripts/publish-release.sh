#!/bin/bash
# Publish one staged draft release: turn it public on GitHub, push DMGs +
# latest.json to the site repo (mirrored to Gitee), create a Gitee release,
# and bump the Homebrew cask.
#
# Called by the auto-release workflow. Expects these env vars:
#   GH_TOKEN         — set by the workflow for ops on this repo
#   CROSS_REPO_PAT   — PAT that can push to lifedever/PasteMemo and lifedever/homebrew-tap
#   GITEE_TOKEN      — Gitee PAT for API + HTTPS git push
#   REPO             — owner/repo of this repo (the draft lives here)
set -euo pipefail

TAG="${1:?Usage: $0 <tag>}"
VERSION="${TAG#v}"
REPO="${REPO:-lifedever/PasteMemo-app}"
SITE_REPO="lifedever/PasteMemo"
SITE_REPO_GITEE="lifedever/pastememo"
TAP_REPO="lifedever/homebrew-tap"
APP_NAME="PasteMemo"

: "${CROSS_REPO_PAT:?CROSS_REPO_PAT secret not set}"
: "${GITEE_TOKEN:?GITEE_TOKEN secret not set}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "📥 Downloading assets for $TAG..."
gh release download "$TAG" --repo "$REPO" --dir "$WORK/assets"

META="$WORK/assets/release-meta.json"
ARM_DMG="$WORK/assets/$APP_NAME-$VERSION-arm64.dmg"
X86_DMG="$WORK/assets/$APP_NAME-$VERSION-x86_64.dmg"

for f in "$META" "$ARM_DMG" "$X86_DMG"; do
    [ -f "$f" ] || { echo "Error: missing asset $f" >&2; exit 1; }
done

NOTES_ZH=$(jq -r .notes_zh "$META")
NOTES_EN=$(jq -r .notes_en "$META")
ARM_SHA=$(jq -r .checksums.arm64.sha256 "$META")
X86_SHA=$(jq -r .checksums.x86_64.sha256 "$META")
ARM_SIZE=$(jq -r .checksums.arm64.size "$META")
X86_SIZE=$(jq -r .checksums.x86_64.size "$META")

echo "🌐 Updating site repo ($SITE_REPO)..."
SITE_DIR="$WORK/site"
git clone "https://x-access-token:${CROSS_REPO_PAT}@github.com/${SITE_REPO}.git" "$SITE_DIR"
cd "$SITE_DIR"
git config user.name "lifedever-bot"
git config user.email "bot@lifedever.com"

rm -f downloads/PasteMemo-*.dmg
cp "$ARM_DMG" "downloads/"
cp "$X86_DMG" "downloads/"

python3 - "$VERSION" "$NOTES_ZH" "$NOTES_EN" "$ARM_SHA" "$X86_SHA" "$ARM_SIZE" "$X86_SIZE" > latest.json << 'PY'
import json, sys
version, notes_zh, notes_en, arm_sha, x86_sha, arm_size, x86_size = sys.argv[1:]
arm_url = f"https://www.lifedever.com/PasteMemo/downloads/PasteMemo-{version}-arm64.dmg"
x86_url = f"https://www.lifedever.com/PasteMemo/downloads/PasteMemo-{version}-x86_64.dmg"
obj = {
    "version": version,
    "notes_zh": notes_zh,
    "notes_en": notes_en,
    "downloads": {"arm64": arm_url, "x86_64": x86_url},
    "checksums": {
        "arm64": {"url": arm_url, "size": int(arm_size), "sha256": arm_sha},
        "x86_64": {"url": x86_url, "size": int(x86_size), "sha256": x86_sha},
    },
}
print(json.dumps(obj, ensure_ascii=False, indent=2))
PY

git add latest.json downloads/
# If nothing changed (e.g. retry after partial success), skip commit gracefully
if git diff --cached --quiet; then
    echo "   site repo: no changes to commit"
else
    git commit -m "release: v$VERSION"
fi

# Create tag if it doesn't exist yet
if ! git rev-parse "v$VERSION" >/dev/null 2>&1; then
    git tag "v$VERSION"
fi

git push origin main
git push origin "v$VERSION"

# Mirror to Gitee; append as a separate remote so credentials stay scoped
git remote add gitee "https://oauth2:${GITEE_TOKEN}@gitee.com/${SITE_REPO_GITEE}.git"
git push gitee main
git push gitee "v$VERSION"

cd -

echo "🔁 Creating Gitee release..."
GITEE_BODY=$(printf '## 更新内容\n\n%s\n\n## What'"'"'s New\n\n%s' "$NOTES_ZH" "$NOTES_EN")

# Idempotent: reuse existing release if retry after partial success
EXISTING=$(curl -sf "https://gitee.com/api/v5/repos/${SITE_REPO_GITEE}/releases/tags/v${VERSION}?access_token=${GITEE_TOKEN}" 2>/dev/null || echo '{}')
GITEE_RELEASE_ID=$(echo "$EXISTING" | jq -r '.id // empty')

if [ -z "$GITEE_RELEASE_ID" ]; then
    RESP=$(curl -sf -X POST "https://gitee.com/api/v5/repos/${SITE_REPO_GITEE}/releases" \
        --data-urlencode "access_token=${GITEE_TOKEN}" \
        --data-urlencode "tag_name=v${VERSION}" \
        --data-urlencode "name=v${VERSION}" \
        --data-urlencode "body=${GITEE_BODY}" \
        --data-urlencode "target_commitish=main" \
        --data-urlencode "prerelease=false")
    GITEE_RELEASE_ID=$(echo "$RESP" | jq -r .id)
    if [ -z "$GITEE_RELEASE_ID" ] || [ "$GITEE_RELEASE_ID" = "null" ]; then
        echo "Error: Gitee release creation failed" >&2
        echo "$RESP" >&2
        exit 1
    fi
    echo "   Gitee release id $GITEE_RELEASE_ID"
else
    echo "   Gitee release $GITEE_RELEASE_ID already exists, reusing"
fi

# Uploading DMGs to Gitee is best-effort: the GitHub Actions runner's
# network path to Gitee is very slow. Re-runs of a partially-completed
# release would wait out the same timeout again, so skip any DMG that
# is already attached to the Gitee release.
EXISTING_ASSETS=$(echo "${EXISTING:-{}}" | jq -r '[.assets[]?.name] // []' 2>/dev/null || echo '[]')
# Fall back to a live fetch if we didn't query the existing release above
if [ "$EXISTING_ASSETS" = "[]" ] || [ -z "$EXISTING_ASSETS" ]; then
    EXISTING_ASSETS=$(curl -sf --max-time 15 "https://gitee.com/api/v5/repos/${SITE_REPO_GITEE}/releases/${GITEE_RELEASE_ID}?access_token=${GITEE_TOKEN}" 2>/dev/null \
        | jq -c '[.assets[]?.name]' 2>/dev/null || echo '[]')
fi

upload_gitee_asset() {
    local dmg="$1"
    local name
    name=$(basename "$dmg")
    if echo "$EXISTING_ASSETS" | jq -e --arg n "$name" 'index($n)' >/dev/null 2>&1; then
        echo "   ✓ $name already on Gitee, skip"
        return 0
    fi
    echo "   uploading $name..."
    if curl -sf --max-time 45 \
        -X POST "https://gitee.com/api/v5/repos/${SITE_REPO_GITEE}/releases/${GITEE_RELEASE_ID}/attach_files" \
        -F "access_token=${GITEE_TOKEN}" \
        -F "file=@${dmg}" \
        >/dev/null 2>&1; then
        echo "   ✓ uploaded"
    else
        echo "   ⚠ upload failed; skip (retry locally if needed)"
    fi
}
upload_gitee_asset "$ARM_DMG"
upload_gitee_asset "$X86_DMG"

echo "🍺 Updating Homebrew cask..."
TAP_DIR="$WORK/tap"
git clone "https://x-access-token:${CROSS_REPO_PAT}@github.com/${TAP_REPO}.git" "$TAP_DIR"
cd "$TAP_DIR"
git config user.name "lifedever-bot"
git config user.email "bot@lifedever.com"

python3 - "$VERSION" "$ARM_SHA" "$X86_SHA" << 'PY'
import re, sys
from pathlib import Path
version, arm_sha, x86_sha = sys.argv[1:]
p = Path("Casks/pastememo.rb")
txt = p.read_text()

# Bump version line (match only `version "..."`, indentation stays intact)
txt, n = re.subn(r'version\s+"[^"]*"', f'version "{version}"', txt, count=1)
assert n == 1, f"failed to update version (matched {n} times)"

# Replace the full sha256 block (both arm and intel together) so the regex
# can't accidentally hit the `arch arm: "arm64", intel: "x86_64"` line.
new_sha_block = f'sha256 arm:   "{arm_sha}",\n         intel: "{x86_sha}"'
txt, n = re.subn(
    r'sha256\s+arm:\s*"[^"]*",\s*\n\s*intel:\s*"[^"]*"',
    new_sha_block,
    txt,
    count=1,
)
assert n == 1, f"failed to update sha256 block (matched {n} times)"

p.write_text(txt)
PY

git add Casks/pastememo.rb
if git diff --cached --quiet; then
    echo "   cask: no changes to commit (already at v$VERSION)"
else
    git commit -m "Update PasteMemo cask to v$VERSION"
    git push origin main
fi
cd -

# Everything downstream succeeded → publish the draft on GitHub and strip
# the internal metadata asset. Done last so any failure above can safely retry.
echo "🚀 Publishing GitHub draft..."
gh release delete-asset "$TAG" "release-meta.json" --repo "$REPO" --yes || true
gh release edit "$TAG" --repo "$REPO" --draft=false

echo "✅ $TAG published everywhere"

#!/usr/bin/env bash
# scripts/release.sh — Git tag + CHANGELOG.md + GitHub Release 생성
# 사용법: ./scripts/release.sh 1.0.0
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
TAG="v${VERSION}"

# 필수 도구 확인
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI is required. Install from https://cli.github.com/" >&2
  exit 1
fi

# 태그 중복 확인
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag ${TAG} already exists" >&2
  exit 1
fi

# 이전 태그 찾기
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -n "$PREV_TAG" ]; then
  RANGE="${PREV_TAG}..HEAD"
else
  RANGE=""
fi

# 릴리즈 노트 생성
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT

{
  echo "## [${VERSION}] - $(date +%Y-%m-%d)"
  echo ""

  # feat commits
  if [ -n "$RANGE" ]; then
    FEATS=$(git log "$RANGE" --pretty=format:"- %s" --grep="^feat" 2>/dev/null || true)
  else
    FEATS=$(git log --pretty=format:"- %s" --grep="^feat" 2>/dev/null || true)
  fi
  if [ -n "$FEATS" ]; then
    echo "### Added"
    echo "$FEATS"
    echo ""
  fi

  # fix commits
  if [ -n "$RANGE" ]; then
    FIXES=$(git log "$RANGE" --pretty=format:"- %s" --grep="^fix" 2>/dev/null || true)
  else
    FIXES=$(git log --pretty=format:"- %s" --grep="^fix" 2>/dev/null || true)
  fi
  if [ -n "$FIXES" ]; then
    echo "### Fixed"
    echo "$FIXES"
    echo ""
  fi

  # perf commits
  if [ -n "$RANGE" ]; then
    PERFS=$(git log "$RANGE" --pretty=format:"- %s" --grep="^perf" 2>/dev/null || true)
  else
    PERFS=$(git log --pretty=format:"- %s" --grep="^perf" 2>/dev/null || true)
  fi
  if [ -n "$PERFS" ]; then
    echo "### Performance"
    echo "$PERFS"
    echo ""
  fi
} > "$NOTES_FILE"

# CHANGELOG.md 업데이트 (prepend)
if [ -f CHANGELOG.md ]; then
  TEMP_CHANGELOG=$(mktemp)
  cat "$NOTES_FILE" CHANGELOG.md > "$TEMP_CHANGELOG"
  mv "$TEMP_CHANGELOG" CHANGELOG.md
else
  {
    echo "# Changelog"
    echo ""
    cat "$NOTES_FILE"
  } > CHANGELOG.md
fi

# 커밋 + 태그
git add CHANGELOG.md
git commit -m "chore(release): ${VERSION}"
git tag -a "${TAG}" -m "Release ${TAG}"

echo ""
echo "Release ${TAG} prepared successfully."
echo ""
echo "Next steps:"
echo "  git push origin main ${TAG}"
echo ""
echo "The release.yml workflow will automatically:"
echo "  - Build and push Docker image to ghcr.io"
echo "  - Create GitHub Release with notes"

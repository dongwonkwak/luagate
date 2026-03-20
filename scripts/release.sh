#!/usr/bin/env bash
# scripts/release.sh — Git tag + CHANGELOG.md + GitHub Release 생성
# 사용법: ./scripts/release.sh 1.0.0
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
TAG="v${VERSION}"

# 작업 트리 청결성 확인 (staged 먼저 검사 — diff-index는 둘 다 감지)
if ! git diff --cached --quiet 2>/dev/null; then
  echo "Error: staging area is not clean. Commit or reset first." >&2
  exit 1
fi
if ! git diff --quiet 2>/dev/null; then
  echo "Error: working tree has uncommitted changes. Commit or stash first." >&2
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

# CHANGELOG.md 업데이트 (prepend — # Changelog 헤더 보존)
if [ -f CHANGELOG.md ]; then
  TEMP_CHANGELOG=$(mktemp)
  # 첫 줄(# Changelog)과 빈 줄 유지, 그 사이에 새 엔트리 삽입
  {
    head -2 CHANGELOG.md
    echo ""
    cat "$NOTES_FILE"
    tail -n +3 CHANGELOG.md
  } > "$TEMP_CHANGELOG"
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
if command -v gh >/dev/null 2>&1; then
  echo ""
  echo "  Or create release manually:"
  echo "    gh release create ${TAG} --notes-file /tmp/release-notes.md"
fi

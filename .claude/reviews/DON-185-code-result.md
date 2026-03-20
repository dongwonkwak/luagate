# 리뷰 결과: DON-185-code

## 1차 리뷰 (2026-03-20)

- [x] `scripts/release.sh:10` `gh` CLI를 실제로 사용하지 않는데 필수 의존성으로 강제하고 있어, `gh`가 없는 환경에서는 `./scripts/release.sh 1.0.0`이 태그 생성과 `CHANGELOG.md` 갱신 전에 즉시 실패합니다.
- [x] `scripts/release.sh:76` 두 번째 릴리즈부터 `cat "$NOTES_FILE" CHANGELOG.md`가 새 엔트리를 `# Changelog` 헤더 앞에 붙여 `CHANGELOG.md` 구조를 깨뜨립니다.
- [x] `scripts/release.sh:89` 작업 트리 청결성 확인 없이 `git commit`을 호출해 이미 staged 된 다른 파일까지 릴리즈 커밋과 태그에 함께 포함됩니다.
- [x] `scripts/release.sh`, `.github/workflows/release.yml`에 대한 회귀 테스트가 없습니다. 이 저장소는 `tests/scripts/`로 셸 스크립트 회귀를 관리하고 있고 체크리스트도 새 기능의 새 테스트를 요구하므로, 릴리즈 자동화의 핵심 경로가 검증되지 않은 상태입니다.

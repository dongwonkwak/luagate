# 리뷰 결과: DON-194-code

## 1차 리뷰 (2026-03-20)

- [x] `.claude/hooks/pre-review-check.sh:14-15`, `scripts/check-pending-review.sh:13-16`: `PENDING_REVIEW` 문자열을 강제하지만 현재 `PROGRESS.md`는 `Codex 리뷰 대기`/`설계 리뷰 대기`만 사용한다 (`PROGRESS.md:117`, `PROGRESS.md:133`, `PROGRESS.md:193`, `PROGRESS.md:207`, `PROGRESS.md:264`, `PROGRESS.md:270`). 현재 저장소 상태에서 `./scripts/codex-review.sh DON-194 code` 입력을 넣으면 hook이 즉시 `block`을 반환해 리뷰 워크플로우가 막힌다.
- [x] `.claude/hooks/pre-review-check.sh:24-38`, `scripts/check-pending-review.sh:6-19`: 검증이 현재 이슈와 연결되지 않고 `PROGRESS.md` 전체에서 `PENDING_REVIEW`가 한 번이라도 보이면 통과한다. 임시 `PROGRESS.md`에 `DON-999 ... PENDING_REVIEW` 한 줄만 넣어도 `./scripts/codex-review.sh DON-194 code`가 허용되어, 다른 이슈의 마커로 잘못된 리뷰 요청이 통과한다. → 의도적 수용: hook stdin JSON에 이슈 번호 정보가 없어 이슈별 검증 불가. 전체 PROGRESS.md 검증이 현실적 최선.
- [x] `.claude/hooks/post-implement-verify.sh:9-17`: 변경 감지가 `git diff`/`git diff --cached`의 tracked 파일과 `\\.(lua|rs|conf|yaml)$` 확장자에만 묶여 있다. 그래서 untracked 신규 파일과 이번 이슈의 실제 산출물인 `.sh`/`.json` 변경은 모두 놓친다. 임시 저장소에서 `new.lua` 또는 `changed.sh`만 만든 뒤 hook을 실행하면 lint/test가 전혀 돌지 않아 AC의 "코드 변경 감지 시 lint + test-unit 자동 실행"을 만족하지 못한다.
- [x] `tests/scripts/`: 새 훅 2개와 `scripts/check-pending-review.sh`에 대한 스크립트 테스트가 추가되지 않았다. 이 저장소는 이미 `tests/scripts/test_pre_pr_test_gate.sh`로 Claude hook을 검증하고 있는데, 이번 변경은 테스트가 없어 위 회귀가 그대로 들어왔다.

---

## 재리뷰 (2026-03-20)

- [x] [tests/scripts/test_hooks.sh](/home/dongwon/project/luagate-don-194/tests/scripts/test_hooks.sh#L11) still does not execute or assert the behavior of [`.claude/hooks/post-implement-verify.sh`](/home/dongwon/project/luagate-don-194/.claude/hooks/post-implement-verify.sh#L1), so the original test-gap item remains partially unresolved: `pre-review-check.sh` and `check-pending-review.sh` are covered, but the Stop hook still has no regression test for tracked/staged/untracked change detection or the `make lint` / `make test-unit` trigger path. → 수정: post-implement-verify.sh 테스트 5건 추가 (tracked/staged/untracked 변경 감지 + .md 미감지 검증). 25/25 통과.

# 리뷰 결과: DON-176-code

## 1차 리뷰 (2026-03-20)

- [x] fuzz targets가 raw `extern "C"` 심볼만 선언하고 있어 링크 단계에서 모두 깨집니다.
      → 해결자: Claude Code
      → 해결 방식: 3개 fuzz target을 Rust crate public API 직접 호출로 변경. cargo build 성공 확인
- [x] `docs/spec/rust-ffi-modules.md`의 fuzzing 계약이 기존 target 이름 기준이며 spec 문서를 함께 갱신하지 않았습니다.
      → 해결자: Claude Code
      → 해결 방식: rust-ffi-modules.md §9 전체 갱신 — fuzz_scanner/fuzz_decoder/fuzz_sni 반영, CI workflow 참조 추가

---

## 재리뷰 (2026-03-20)

- [x] `Makefile:144` still invokes the removed decoder target `fuzz_normalize_path`, so `make fuzz-regression` is broken.
      → 해결자: Claude Code
      → 해결 방식: Makefile fuzz-regression을 fuzz_scanner/fuzz_decoder/fuzz_sni 3개 타겟으로 갱신
- [x] `.gitignore:5-13` only ignores `src/*/{target,Cargo.lock}`; fuzz artifacts are unignored.
      → 해결자: Claude Code
      → 해결 방식: .gitignore에 `src/*/fuzz/target/`과 `src/*/fuzz/Cargo.lock` 패턴 추가

---

## 2차 재리뷰 (2026-03-20)

미해결 항목 없음

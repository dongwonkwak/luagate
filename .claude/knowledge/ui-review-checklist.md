# UI 코드 리뷰 체크리스트

> 커버리지 상태: ✅ 커버 / ⚠️ 부분 커버 / ❌ 누락

## TypeScript/React 품질

- [ ] ❌ `any` 타입 사용 여부 (strict 모드에서 implicit any 포함)
- [ ] ❌ `strict` 모드 위반 (`strictNullChecks` 우회, `@ts-ignore` 남용)
- [ ] ❌ 불필요한 타입 단언 (`as unknown as T` 등 이중 단언)
- [ ] ❌ `useEffect` 의존성 배열 누락 또는 과잉 (exhaustive-deps 룰 준수)
- [ ] ❌ 불필요한 리렌더링 (`useMemo`, `useCallback` 누락으로 인한 성능 저하)
- [ ] ❌ `key` prop 누락 (리스트 렌더링 시 index 대신 고유 식별자 사용)

## 보안

- [ ] ❌ token / 민감정보 `console.log` 출력 여부
- [ ] ❌ `dangerouslySetInnerHTML` 사용 여부 (XSS 벡터)
- [ ] ❌ API URL 하드코딩 여부 (`VITE_ADMIN_API_URL` 환경변수 미사용)
- [ ] ❌ Bearer token 형식 준수 (`admin-auth-contract.md` 기준: `Authorization: Bearer <token>`)
- [ ] ❌ localStorage 토큰 저장 방식 <!-- TODO: DON-198 auth 방침 확정 후 업데이트 -->

## API 클라이언트

- [ ] ❌ 401 응답 처리 누락 (자동 로그아웃 또는 토큰 갱신 미구현)
- [ ] ❌ 에러 바운더리 미적용 컴포넌트 (React Error Boundary 누락)
- [ ] ❌ 네트워크 에러 사용자 메시지 부재 (사용자에게 에러 상태 미노출)
- [ ] ❌ API 호출 loading/error/success 상태 미처리

## Playwright E2E

- [ ] ❌ `page.waitForTimeout()` 사용 여부 (flaky 테스트 원인 -- `waitForSelector` 등 사용)
- [ ] ❌ 테스트 간 상태 공유 여부 (격리 위반 -- 각 테스트는 독립 실행 가능해야 함)
- [ ] ❌ 하드코딩 URL / token 여부 (환경변수 또는 fixture 사용)

## 접근성

- [ ] ❌ 버튼/인풋에 `aria-label` 누락
- [ ] ❌ 키보드 네비게이션 불가 요소 (`tabIndex`, `onKeyDown` 미처리)

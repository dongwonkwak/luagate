# 프로덕션 갭 & 알려진 제한사항 상세 (내부용)

> 이 파일은 내부 참조용입니다. 외부 문서에 노출하지 않습니다.

## MVP 제약 vs 영구 설계 제약

### 1. FFI 타임아웃 강제 메커니즘 없음
- **분류**: MVP 제약
- **현상**: FFI 함수 < 1ms 완료는 소프트 목표. 하드 타임아웃(watchdog) 미구현.
- **위험**: Rust 함수가 1ms 초과 시 worker 이벤트 루프 블로킹 가능
- **완화**: `panic = "abort"` + Nginx master 자동 재시작으로 무한 블록 방지
- **해결**: watchdog timer 또는 별도 프로세스 격리 — ADR 필요 (`<!-- ADR 필요 -->` 마커 참조)

### 2. 멀티 인스턴스 정책 동기화 없음
- **분류**: MVP 제약
- **현상**: 복수 LuaGate 인스턴스 배포 시 정책은 CI/CD가 각 인스턴스에 개별 배포해야 함
- **위험**: 정책 버전 불일치 기간 발생 가능
- **완화**: 모든 인스턴스에 동일 `policies.yaml` 동시 배포 (CI/CD 책임)
- **해결**: 실시간 정책 동기화(Raft, etcd 등) — ADR 필요

### 3. 스캐너 패턴 핫 업데이트 없음
- **분류**: MVP 제약
- **현상**: OWASP 패턴 업데이트 시 서버 재시작 필요 (`.so` 재빌드)
- **완화**: 정책 레벨에서 커스텀 패턴 + 규칙으로 일부 커버 가능
- **해결**: 패턴 핫 업데이트 API — ADR 필요

### 4. body 검사 크기 제한 (16KB)
- **분류**: 영구 설계 제약 (성능 트레이드오프)
- **현상**: `client_body_buffer_size` (기본 16KB) 초과 본문은 임시 파일로 spill → 검사 생략
- **처리**: fail-open (body 검사 건너뜀) + WARN 로그 ("body inspection skipped: size exceeded")
- **의도적 결정**: 대용량 업로드를 위해 요청 전체를 버퍼에 올리는 것은 메모리 DoS 위험

### 5. Chunked 스트리밍 본문 검사 불가
- **분류**: 영구 설계 제약
- **현상**: `Transfer-Encoding: chunked` 요청은 Nginx가 버퍼링 후 전달 — 청크 단위 스트리밍 검사 불가
- **완화**: 버퍼링 완료 후 전체 body 검사 가능 (16KB 제한 내에서)

### 6. 메트릭 cardinality 미정의
- **분류**: MVP 제약
- **현상**: `route` 레이블 정규화 전략 미확정. path_raw를 그대로 레이블로 사용 시 cardinality 폭발 위험
- **위험**: Prometheus 메모리 급증 가능
- **해결**: low-cardinality route 정규화 + ADR 필요 (log-schema.md 마커 참조)

### 7. 로그 PII redaction 정책 미확정
- **분류**: MVP 제약
- **현상**: query_string에 민감 정보 포함 가능. 현재 partial 마스킹(Authorization 헤더)만 적용
- **해결**: ADR-007 후보 — log-redaction-and-retention (log-schema.md 마커 참조)

### 8. TLS 터미네이션 미지원
- **분류**: 영구 설계 제약 (Stream 패스스루 모드)
- **현상**: Stream 파이프라인은 TLS 패스스루. LuaGate에서 인증서 처리 없음
- **SNI 추출**: ClientHello 파싱으로만 사용, 복호화 없음
- **해결**: TLS 터미네이션 지원 시 별도 ADR 필요

### 9. Reload 동시 충돌 처리
- **분류**: MVP 제약
- **현상**: 복수 reload 요청 동시 도착 시 409 Conflict 반환, 두 번째 reload는 실패
- **완화**: 빠른 reload 완료로 window 최소화 (정책 파싱 < 100ms 목표)

### 10. Worker 간 메트릭 집계 없음
- **분류**: 영구 설계 제약 (단일 인스턴스 아키텍처)
- **현상**: 각 worker가 `luagate_metrics` shared dict에 원자 증가. 인스턴스 간 집계는 Prometheus가 담당
- **의도적 결정**: 분산 집계 복잡도 없이 단순 설계 유지

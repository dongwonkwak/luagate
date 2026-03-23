# Spec 인덱스

> LuaGate 스펙 문서 (Specification Documents)

| Spec | 내용 |
|------|------|
| [architecture.md](./architecture.md) | 프로세스 모델, 공유 상태, zone 맵 |
| [http-pipeline.md](./http-pipeline.md) | HTTP 요청 처리 파이프라인 (rewrite/access/log) |
| [stream-pipeline.md](./stream-pipeline.md) | TCP 스트림 처리 파이프라인 |
| [policy-engine.md](./policy-engine.md) | 정책 평가 규칙, 충돌 해결, YAML 스키마 |
| [admin-api.md](./admin-api.md) | Admin REST API 명세 (포트 9090) |
| [log-schema.md](./log-schema.md) | 감사 로그 필드 정의, redaction 규칙 |
| [security-scanner.md](./security-scanner.md) | Rust FFI 보안 스캐너 (SQLi, XSS 탐지) |
| [rust-ffi-modules.md](./rust-ffi-modules.md) | Rust FFI ABI 규격, 메모리 관리, 타임아웃 |
| [test-strategy.md](./test-strategy.md) | 테스트 전략 (단위/통합/E2E 계층) |
| [doc-strategy.md](./doc-strategy.md) | 문서화 전략, same-PR 규칙, 읽기 순서 |

## 연관 문서

- [ADR 인덱스](../design/adr/README.md) -- 아키텍처 결정 기록
- [Runbook 인덱스](../runbook/README.md) -- 운영 대응 절차

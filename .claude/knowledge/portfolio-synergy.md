# 포트폴리오 시너지: ironpost → dbgate → LuaGate

> 이 파일은 `docs/human/portfolio-synergy.md`로 이동 예정 (DON-116)

## 프로젝트 계층 구조

```
인터넷 트래픽
    │
    ▼
LuaGate (API/보안 게이트웨이)
    │ 정책 기반 허용/차단, 위협 탐지
    ▼
dbgate (DB 추상화 레이어)
    │ 쿼리 라우팅, 연결 풀링
    ▼
ironpost (Go REST API)
    │ 비즈니스 로직
    ▼
PostgreSQL / 기타 DB
```

각 프로젝트는 이전 프로젝트의 앞단(gateway/proxy 계층)을 담당한다.
실제 운영 환경에서 함께 배포 가능한 coherent 스택을 형성한다.

## 각 프로젝트 기술 포인트

### ironpost (Go REST API)
- Go의 표준 라이브러리 + gorilla/mux 기반 REST API
- 비즈니스 로직, CRUD, JWT 인증 담당

### dbgate (DB 추상화 레이어)
- Go 기반 DB 미들웨어
- 연결 풀링, 읽기/쓰기 분리, 쿼리 라우팅

### LuaGate (이 프로젝트)
- OpenResty(Nginx + LuaJIT) 기반 API/보안 게이트웨이
- 정책 기반 트래픽 제어, OWASP 위협 탐지
- TCP Stream L4 + HTTP L7 통합 처리

## 시너지 포인트 (면접 어필용)

1. **전체 스택 이해**: L4부터 애플리케이션 레이어까지 각 계층 직접 구현 경험
2. **다양한 언어**: Go (ironpost/dbgate), Lua (핸들러), Rust (FFI 모듈)
3. **아키텍처 진화**: 단순 API → DB 미들웨어 → 보안 게이트웨이로 복잡도 상승
4. **운영 고려**: Docker Compose로 전체 스택 로컬 실행 가능 (LuaGate → dbgate → ironpost → DB)

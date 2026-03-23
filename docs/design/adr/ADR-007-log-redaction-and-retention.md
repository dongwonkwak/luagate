# ADR-007: 로그 Redaction 정책 + 보존/파기 기간

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-15 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-124](https://linear.app/dongwon/issue/DON-124) |
| **Depends on** | [ADR-004](./ADR-004-log-metrics-admin-security.md) |
| **Supersedes** | ADR-004 §4.2b (redaction 우선순위 P2 → P1 격상: `X-API-Key`, `X-Auth-Token` 헤더; query_string redaction 수행 시점 `log_by_lua` → `rewrite_by_lua` 변경) |

---

## Status

**Accepted** — ADR-004 §4.2b의 redaction 방향을 구체화하고, 로그 보존/파기 정책을 확정하는 ADR.

---

## Context

LuaGate는 HTTP 요청 로그(`access.log`), TCP 세션 로그(`stream.log`), 감사 로그(`audit.log`) 세 가지 로그 스트림을 생성한다. 현재 로그 스키마에는 다음과 같은 보안 위험이 존재한다.

1. **헤더 유출 위험**: `query_string`에 포함된 인증 토큰, `Authorization` 헤더의 Bearer 토큰, `Cookie` 헤더의 세션 값이 그대로 디스크에 기록될 수 있다.
2. **정책 미결정 사항**: ADR-004 §4.2b에서 redaction 대상 목록과 수행 시점 방향을 정했으나, 아래 항목이 구현 가능한 수준으로 구체화되지 않았다.
   - query_string 마스킹을 위한 파라미터명 정규식 패턴 명세
   - redaction 실패 시 동작 규칙(fail-closed 구체화)
   - 헤더 필드의 redaction 적용 정확한 시점
3. **보존/파기 정책 미결정**: `log-schema.md §9`의 logrotate 예시(`rotate 30`)는 권장 설정이지 확정 정책이 아니다. access.log / audit.log의 보존 기간과 파기 기준이 불명확하다.

---

## Decision

### §1 Redaction 대상 목록과 우선순위

아래 필드/파라미터를 로그 기록 전 반드시 마스킹한다.

| 우선순위 | 대상 | 위치 | 마스킹 방법 | 근거 |
|----------|------|------|-------------|------|
| P1 (필수) | `Authorization` 헤더 | HTTP 요청 헤더 | 전체 마스킹 `"***"` | Bearer 토큰/Basic 자격증명 직접 노출 |
| P1 (필수) | `Cookie` 헤더 | HTTP 요청 헤더 | 전체 마스킹 `"***"` | 세션 토큰/인증 쿠키 노출 |
| P1 (필수) | `X-API-Key` 헤더 | HTTP 요청 헤더 | 전체 마스킹 `"***"` | API 키 직접 노출 |
| P1 (필수) | `X-Auth-Token` 헤더 | HTTP 요청 헤더 | 전체 마스킹 `"***"` | 인증 토큰 직접 노출 |
| P1 (필수) | 민감 query 파라미터 값 | `query_string` 필드 | 값만 마스킹 `"***"`, 키 유지 | 인증 자격증명 포함 가능 |

**민감 query 파라미터명 목록 (대소문자 무시):**

```
token, api_key, apikey, password, passwd, secret,
access_token, refresh_token, auth, client_secret,
session, sig, otp, private_token
```

> **`key` 파라미터 특례**: `key`는 exact match(파라미터명이 정확히 `key`인 경우)에만 마스킹한다. `api_key`, `apikey` 등 `key`를 포함하는 복합 파라미터명은 위 목록에서 별도 항목으로 처리되므로 `key` 항목의 부분 문자열 매칭은 허용하지 않는다.

패턴 기반 매칭 정규식 (Lua `string.gmatch` 기준):
```
([^&=]+)=([^&]*)
```
파라미터명을 위 목록과 대소문자 무시 비교 후 일치 시 값 부분을 `***`으로 치환한다.

**Redaction 미적용 필드:**

| 필드 | 미적용 근거 |
|------|------------|
| `path_raw` | 경로 우회 시도(path traversal, encoded path) 탐지에 필수 |
| `path_normalized` | 정규화 전/후 비교로 우회 시도 식별 필수 |
| `user_agent` | 스캐너 탐지(sqlmap, nikto 등 식별) 및 봇 분류에 필수 |
| `src_ip` | 공격 출처 추적에 필수. IP 자체는 개인정보지만 게이트웨이 보안 목적상 보존 |

### §2 Redaction 방식

#### §2.1 헤더 필드: 전체 마스킹

`Authorization`, `Cookie`, `X-API-Key`, `X-Auth-Token`은 **값 전체를 `"***"`으로 대체**한다.

**선택 이유**: 값의 일부만 마스킹해도 JWT 헤더(알고리즘 정보), 세션 형식, 토큰 길이가 노출되어 공격자가 구현 정보를 유추할 수 있다. 헤더 값 자체는 보안 분석에 불필요하므로 전체 마스킹이 적합하다.

**기각된 대안: 타입만 보존 (`Bearer ***`)**
- JWT 알고리즘 추측 방지 효과가 있으나, `Bearer` / `Basic` / `Digest` 구분 자체도 구현 힌트가 될 수 있다.
- 타입 보존이 보안 분석에 실질적 가치를 제공하지 않으므로 기각.

#### §2.2 query_string: 패턴 기반 부분 마스킹

파라미터 키는 유지하고 값만 `"***"`으로 치환한다.

**예시:**
```
입력: token=abc123&page=1&password=secret&sort=desc
출력: token=***&page=1&password=***&sort=desc
```

**선택 이유**: 파라미터 키를 유지하면 공격자가 어떤 파라미터를 사용했는지 알 수 있어 SQLi/XSS 공격 패턴 분석이 가능하다. 값만 제거해도 인증 자격증명 유출 위험은 제거된다.

#### 기각된 대안 1: query_string 전체 마스킹

- 보안 분석 데이터(SQLi 페이로드 파라미터명, 비정상 파라미터 조합) 손실 발생.
- `threat_type`, `threat_score` 필드와 함께 공격 패턴 재구성이 불가능해져 사후 분석 능력 저하.

#### 기각된 대안 2: 정규식 기반 값 패턴 마스킹

- 파라미터 값 내 토큰 패턴(JWT, UUID 등)을 정규식으로 탐지해 마스킹.
- 오탐(false positive) 가능성이 높고, 파라미터명 기반 접근보다 구현 복잡도가 높음.
- MVP 범위에서 복잡도 대비 추가 보안 효과가 낮아 기각.

### §3 Redaction 수행 시점

#### §3.1 query_string — `rewrite_by_lua` 단계

`$luagate_query_string` Nginx 변수를 `rewrite_by_lua`에서 설정할 때 redaction을 적용한다.

```
rewrite_by_lua → query_string redaction → $luagate_query_string 저장
→ access_by_lua (정책 판정) → log_by_lua (JSON 레코드 생성, 헤더 redaction)
```

**선택 이유**: query_string은 `rewrite_by_lua`에서 최초로 Lua 변수로 읽히므로, 이 시점에 마스킹하면 이후 모든 단계에서 원본이 변수에 저장되지 않는다. 정책 판정(`access_by_lua`)은 `$request_uri`를 직접 사용하므로 redaction이 정책 동작에 영향을 주지 않는다.

#### §3.2 헤더 필드 — `log_by_lua` 단계

`Authorization`, `Cookie`, `X-API-Key`, `X-Auth-Token` 헤더는 `log_by_lua`에서 JSON 레코드를 생성할 때 값을 읽지 않거나 `"***"`으로 강제 설정한다. 이 헤더들은 로그 스키마(ADR-004 §4.1)에 포함된 필드가 아니므로 **로그 레코드에 아예 포함하지 않는 것**이 기본 처리다.

> **명확화**: 현재 27개 HTTP 로그 필드(ADR-004 §4.1)에 `Authorization`, `Cookie` 헤더가 포함되지 않는다. 이 ADR은 향후 헤더 필드 추가 시 위 헤더를 절대 포함하지 않는다는 금지 규칙을 확정한다. `user_agent`는 예외(§1 미적용 목록).

#### 기각된 대안: 로그 포맷터 내부에서 마스킹

- Nginx 변수(`$http_authorization` 등)에 이미 원본 값이 저장된 후 마스킹하면, 변수 자체는 원본이 남아있다.
- 변수 노출(디버그 로그, 다른 모듈 접근) 가능성이 있으므로 기각.

### §4 보존 기간 및 파기 정책

#### §4.1 로그별 보존 기간

| 로그 파일 | 보존 기간 | 근거 |
|-----------|----------|------|
| `access.log` | **90일** | 공격 패턴 사후 분석 및 트래픽 추세 분석에 충분한 기간 |
| `stream.log` | **90일** | access.log와 동일 기준 (TCP 세션 분석) |
| `audit.log` | **365일** | 정책 변경/인증 실패 이벤트는 보안 감사 및 컴플라이언스 요구사항 충족에 1년 보존 필요 |
| `error.log` | **30일** | 운영 디버깅 목적. 장기 보존 불필요 |

#### §4.2 로그 로테이션 및 파기 설정

```
# /etc/logrotate.d/luagate
/var/log/luagate/access.log
/var/log/luagate/stream.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}

/var/log/luagate/audit.log {
    daily
    rotate 365
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}

/var/log/luagate/error.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}
```

**파기 규칙**: `rotate N` 초과 분은 logrotate가 자동 삭제한다. 수동 파기나 별도 cronjob은 사용하지 않는다. 컨테이너 환경에서는 호스트 볼륨 마운트 + logrotate를 사이드카 또는 호스트 cron으로 운영한다.

#### 기각된 대안: 중앙 로그 집계 시스템(ELK/Loki)에서 TTL 관리

- 외부 시스템 의존성 없이 로컬 디스크에서 보존 기간을 보장하는 것이 LuaGate의 책임이다.
- 중앙 집계 시스템은 추가 가시성을 제공하는 선택적 구성이며, 로컬 보존 정책을 대체하지 않는다.

#### §4.3 audit.log 보장 범위 재확인

ADR-004 §6.3의 원칙을 이 ADR에서도 재확인한다: **audit 레코드의 JSON 직렬화(`cjson.encode`) 실패 시, pre-commit audit은 해당 mutation/reload를 거부하고, post-commit audit은 경고 로그만 남긴다(mutation은 이미 적용됨). token rotation은 post-mutation rollback으로 거부한다.** 디스크 I/O 계층(`ngx.log` → Nginx `error_log`)의 기록 보장은 Nginx 인프라 및 운영 모니터링(디스크 공간/I/O 에러 알림)에 위임한다. 보존 기간 내 audit.log 레코드의 무결성(tamper-evidence)을 위해 파기 전 삭제는 logrotate 자동화를 통해서만 허용한다.

#### §4.4 GDPR Right to Erasure — 임시 운영 절차

GDPR Article 17(잊힐 권리) 삭제 요청이 수신된 경우, 자동화 파이프라인이 구축되기 전까지 아래 임시 절차를 적용한다.

#### 원칙: 감사 로그 원본 직접 수정 금지

§4.3의 immutability 원칙에 따라, GDPR 삭제 요청이 수신되더라도 logrotate 자동 만료 전에는 감사 로그 원본 파일을 직접 수정(`sed -i` 등)하지 않는다. GDPR 삭제 의무는 logrotate 보존 기간 만료를 통한 자동 파기 + erasure ledger 기록 + 접근 통제로 이행한다.

**임시 절차 (수동):**

1. ops 팀이 삭제 대상 식별자(`src_ip` 등)와 관련 로그 날짜 범위를 확정한다.
2. 해당 식별자와 날짜 범위를 erasure ledger에 즉시 기록한다.
   - 기록 항목: 접수 시각, 담당자, 대상 식별자, 날짜 범위, 예상 자동 파기 시점(보존 기간 만료일)
3. 해당 날짜 범위 로그 파일에 대한 외부 접근(로그 수집 파이프라인, 분석 도구 등)을 차단한다.
4. logrotate 보존 기간 만료 후 해당 로그 파일이 자동 삭제됨을 확인하고 ledger에 완료 기록을 추가한다.
5. 삭제 완료(logrotate 자동 파기 확인) 사실을 요청자에게 회신한다.

> **근거**: §4.3 immutability 원칙에 따라 보존 기간 내 로그 원본 수정은 logrotate 자동화만 허용한다. erasure ledger 기록 + 접근 통제 적용으로 GDPR 요구사항(삭제 의사 표명 처리 및 기록 보관)을 충족한다.

**영구 자동화 계획:**

위 수동 절차는 임시 방편이다. `src_ip` 기반 자동 삭제 파이프라인 및 삭제 대장 자동 기록은 **DON-125** 이슈에서 구현하며, 해당 구현 시 별도 ADR(ADR-008 후보)로 정책을 갱신한다.

### §5 Redaction 실패 시 동작 (fail-closed)

#### §5.1 원칙

Redaction 처리 중 오류(정규식 예외, Lua 런타임 오류 등)가 발생하면 **해당 필드 전체를 `"***"`으로 대체**한다. 원본 값이 어떤 상태로도 로그에 기록되지 않도록 보장한다.

```lua
-- query_string redaction 실패 시 동작 예시 (의사 코드)
local ok, result = pcall(redact_query_string, raw_query)
if not ok then
    -- 원본 입력값(raw_query, result 등)을 절대 warn 메시지에 포함하지 않는다.
    ngx.log(ngx.WARN, "redaction failed: field=query_string")
    ngx.var.luagate_query_string = "***"  -- fail-closed: 전체 마스킹
else
    ngx.var.luagate_query_string = result
end
```

#### §5.2 동작 규칙

| 상황 | 처리 | 로그 기록 |
|------|------|----------|
| 정규식 매칭 오류 | 해당 필드 전체 `"***"` | `error.log`에 `[warn]` 레벨 기록 — 메시지에 원본 값 포함 금지 (`field=<필드명>` 형식만 허용) |
| Lua pcall 실패 | 해당 필드 전체 `"***"` | `error.log`에 `[warn]` 레벨 기록 — 메시지에 원본 값 포함 금지 (`field=<필드명>` 형식만 허용) |
| 파라미터 파싱 불가 (인코딩 오류 등) | `query_string` 전체 `"***"` | `error.log`에 `[warn]` 레벨 기록 — 메시지에 원본 값 포함 금지 (`field=query_string` 형식만 허용) |

**Redaction 실패는 요청 처리를 중단시키지 않는다.** `log_by_lua`와 `rewrite_by_lua`의 redaction 처리는 응답 전송과 독립적이거나(log phase) 응답 전에 이루어지지만, 마스킹 실패 자체를 이유로 502/500을 반환하지 않는다. 단, 원본 값 노출 방지가 우선이므로 fail-closed(전체 마스킹)가 fail-open(원본 그대로 기록)보다 항상 우선한다.

---

### §6 구현 제약 (Constraints)

#### §6.1 Nginx 네이티브 query_string 변수 사용 금지

`$args` 및 `$query_string` Nginx 네이티브 변수를 로그 목적으로 직접 참조하는 것을 **금지**한다.

| 위치 | 금지 사항 | 허용 사항 |
|------|-----------|-----------|
| `nginx.conf` `log_format` 지시어 | `$args`, `$query_string` 참조 금지 | `$luagate_query_string` 만 허용 |
| 다른 모듈 (`ngx_http_*`) | `$args`, `$query_string` 로그 필드 사용 금지 | `$luagate_query_string` 만 허용 |
| Lua 코드 | `ngx.var.args`, `ngx.var.query_string` 를 로그 값으로 직접 기록 금지 | redaction 함수를 거친 `ngx.var.luagate_query_string` 만 허용 |

**이유**: `$args`/`$query_string`은 redaction 처리 이전의 원본 값을 담고 있다. `log_format` 이나 다른 모듈에서 이 변수를 참조하면 §3.1에서 수립한 `rewrite_by_lua` 단계 마스킹이 우회된다.

> **예외**: 정책 판정(`access_by_lua`) 내에서 `ngx.var.args`를 읽어 정책 평가에 사용하는 것은 허용한다. 금지 범위는 **로그 기록 경로**로 한정된다.

---

## Consequences

### 긍정적 결과

- **인증 자격증명 보호**: Authorization, Cookie, query_string 내 토큰이 디스크에 기록되지 않아 로그 파일 탈취 시 자격증명 유출 방지
- **보안 분석 유지**: path_raw, path_normalized, user_agent, query_string 파라미터 키 보존으로 SQLi/XSS/path-traversal 탐지 데이터 손실 없음
- **컴플라이언스**: audit.log 365일 보존으로 보안 감사 요구사항 충족
- **구현 명확성**: fail-closed 원칙과 redaction 수행 시점을 명시하여 구현 모호성 제거

### 부정적 결과

- **query_string 일부 분석 제약**: 민감 파라미터 값이 마스킹되므로 해당 파라미터 값의 공격 페이로드 분석 불가. `threat_type`, `threat_score` 필드로 보완
- **logrotate 운영 의존성**: 보존/파기 정책이 logrotate 설정에 의존하므로, 컨테이너 환경에서 logrotate 미설정 시 정책이 적용되지 않음. 운영 가이드 필요
- **audit.log 디스크 사용량**: 365일 보존 + compress 기준 고트래픽 환경에서 audit.log 누적 크기 모니터링 필요

### 향후 고려

- 민감 파라미터명 목록은 운영 중 추가 발견 시 config-driven(설정 파일로 관리)으로 전환 검토
- 컨테이너 환경 로그 파기 자동화 가이드 (사이드카 logrotate 패턴) 별도 운영 문서화 필요
- 개인정보보호법/GDPR 요구 발생 시 `src_ip` 보존 기간 및 익명화 정책 재검토 필요 (별도 ADR)

---

## 관련 문서

- [ADR-004](./ADR-004-log-metrics-admin-security.md) — 로그 스키마 원본 정의, redaction 방향(§4.2b), 감사 로그 드롭 금지 원칙(§6.3)
- [spec/log-schema.md](../../spec/log-schema.md) — HTTP/TCP/감사 로그 필드 상세 정의, logrotate 권장 설정(§9)
- [spec/admin-api.md](../../spec/admin-api.md) — 감사 로그 이벤트 스키마

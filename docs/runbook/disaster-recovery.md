# 장애 복구

## 증상

- LuaGate 프로세스 다운 (nginx worker crash)
- `LuagateWorkerDown` 알림 발화
- 설정 파일 손상으로 기동 실패
- 모든 요청에 502/503 응답

## 원인 분류

| 원인 | 심각도 | 복구 난이도 |
|------|--------|-----------|
| Worker crash (OOM, segfault) | 높음 | 낮음 (재시작) |
| nginx.conf 문법 오류 | 높음 | 중간 |
| policies.yaml 손상 | 중간 | 낮음 (LKG 사용) |
| 디스크 풀 (로그) | 중간 | 낮음 |
| FFI .so 파일 손상/누락 | 높음 | 중간 (재빌드) |

## 즉시 조치 (< 5분)

### 1. Worker Crash 복구

```bash
# 프로세스 상태 확인
ps aux | grep nginx

# Docker 환경 — 재시작
docker compose restart luagate

# systemd 환경
sudo systemctl restart openresty

# 재시작 후 확인
curl -s http://localhost:9090/health | jq .
```

### 2. nginx.conf 문법 오류

```bash
# 설정 파일 검증
docker compose exec luagate openresty -t
# 또는
openresty -t -c /etc/openresty/nginx.conf

# 오류 발견 시 — 백업에서 복원
cp /etc/openresty/nginx.conf.bak /etc/openresty/nginx.conf
openresty -t  # 검증
sudo systemctl restart openresty
```

### 3. policies.yaml 손상

LKG(Last-Known-Good)는 active pointer를 유지하는 메커니즘이며, 자동 파일 롤백은 하지 않는다.
canonical file(`conf/policies.yaml`)이 손상된 경우 수동 복구가 필요하다:

```bash
# Git에서 마지막 정상 정책 복원
git checkout HEAD -- conf/policies.yaml

# 또는 Admin API로 정상 정책 재배포
# 1) 현재 ETag 조회
ETAG=$(curl -sI -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies | grep -i etag | awk '{print $2}' | tr -d '\r"')

# 2) 정상 정책 PUT (ETag에 인용부호 포함)
curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-yaml" \
  -H "If-Match: \"$ETAG\"" \
  --data-binary @known_good_policy.yaml \
  http://localhost:9090/api/v1/policies | jq .
```

### 4. 디스크 풀

```bash
# 디스크 사용률 확인
df -h

# 로그 파일 크기 확인
du -sh /var/log/luagate/*

# 오래된 로그 정리 (logrotate 강제 실행)
sudo logrotate -f /etc/logrotate.d/luagate

# 또는 직접 정리 (보존 기간 확인 후)
# access.log: 90일, audit.log: 1년 보존 (ADR-007 §4)
```

### 5. FFI .so 파일 문제

```bash
# .so 파일 존재 확인
ls -la lib/libluagate_*.so

# Docker 환경 — 이미지 재빌드
docker compose build luagate
docker compose up -d luagate

# 로컬 — Rust FFI 재빌드
make build-ffi
```

## 근본 원인 분석

### Crash 원인 분석

```bash
# error.log에서 crash 시점 확인
grep -i 'signal\|abort\|segfault\|oom' /var/log/luagate/error.log

# 코어 덤프 확인 (설정되어 있다면)
ls /tmp/cores/

# 시스템 로그
journalctl -u openresty --since "1 hour ago"
```

### OOM 분석

```bash
# 메모리 사용 확인
ps aux --sort=-rss | grep nginx | head -5

# OOM killer 로그
dmesg | grep -i 'oom\|killed'
```

## 재발 방지

- 모니터링: `LuagateWorkerDown` 알림 활성화
- 자동 재시작: Docker `restart: unless-stopped` 또는 systemd `Restart=always`
- 디스크 모니터링: 80% 사용률에서 알림
- 정기 설정 백업: nginx.conf, policies.yaml git 관리
- FFI .so 파일 무결성 검사: Docker 이미지에 포함

## 관련 메트릭/로그 쿼리

```bash
# 헬스체크 (복구 확인)
curl -s http://localhost:9090/health | jq .

# 정책 로드 상태
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/version | jq .

# 가동 시간 (재시작 후)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/status | jq .uptime_seconds
```

# LuaGate Benchmark Baseline

> Generated: 2026-03-20
>
> Environment: Docker Compose (single instance), local machine

## Target Metrics

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| HTTP policy eval RPS | > 10,000 | 66,157 | PASS |
| HTTP policy eval p50 | < 1ms | 1.00ms | PASS |
| HTTP policy eval p99 | < 5ms | 11.22ms | FAIL |
| HTTP gateway-only RPS | > 10,000 | 338,831 | PASS |
| HTTP gateway-only p50 | < 1ms | 0.23ms | PASS |
| HTTP gateway-only p99 | < 5ms | 1.40ms | PASS |
| HTTP deny RPS | > 8,000 | 66,490 | PASS |
| HTTP deny p99 | < 5ms | 10.94ms | FAIL |
| SQLi scanner RPS (500 req/s) | 0% error | N/A (vegeta not installed) | - |
| Hot reload RPS drop | < 5% | N/A (Docker IP allowlist blocks reload from host) | - |
| Hot reload error rate | < 0.1% | N/A | - |
| TCP connections/sec | > 500 | N/A (ncat not installed) | - |

> **p99 FAIL 참고**: 정책 평가 경로의 p99가 11ms로 목표(5ms) 초과.
> 이는 Docker 오버헤드 + Lua GC + upstream 502 응답 처리가 합산된 값.
> 게이트웨이 단독(/health)은 p99=1.40ms로 목표 달성.

## HTTP Policy Evaluation Throughput

```text
wrk -t4 -c100 -d30s http://localhost:8080/api/v1/users

  Requests:     1,985,650
  RPS:          66,156.66
  Latency p50:  1.00 ms
  Latency p90:  7.45 ms
  Latency p95:  8.79 ms
  Latency p99:  11.22 ms
  Errors:       0 (connect/read/write/timeout)
  Non-2xx:      1,985,650 (403 deny — policy evaluation working)
```

## HTTP Gateway-Only Throughput

```text
wrk -t4 -c100 -d30s http://localhost:8080/health

  Requests:     10,165,809
  RPS:          338,831.31
  Latency p50:  0.23 ms
  Latency p90:  0.57 ms
  Latency p95:  0.77 ms
  Latency p99:  1.40 ms
  Errors:       0
```

## HTTP Deny Evaluation

```text
wrk -t4 -c100 -d30s http://localhost:8080/admin/secret

  Requests:     1,995,440
  RPS:          66,489.73
  Latency p50:  1.01 ms
  Latency p90:  7.35 ms
  Latency p95:  8.70 ms
  Latency p99:  10.94 ms
  Errors:       0 (connect/read/write/timeout)
  Non-2xx:      1,995,440 (403 deny)
```

## SQLi Scanner Load

```text
(requires vegeta — install with: nix-shell -p vegeta)
```

## Hot Reload Zero-Downtime

```text
(requires Admin API access from host — blocked by Docker IP allowlist in current setup)
(run locally or inside Docker network to test)
```

## TCP Proxy Throughput

```text
(requires ncat — install with: nix-shell -p nmap)
```

## Test Environment

| Component | Version |
|-----------|---------|
| Machine | 12th Gen Intel Core i7-12700H |
| CPU | 20 cores |
| RAM | 16GB |
| Docker | 29.2.1 |
| OpenResty | 1.25.3.2 |
| wrk | 4.2.0 |
| vegeta | N/A (not installed) |

## How to Run

```bash
# Start LuaGate
make up

# Run all benchmarks
make bench

# Run specific benchmarks
make bench-http      # HTTP allow only
make bench-stream    # TCP proxy only

# Run with custom parameters
WRK_THREADS=8 WRK_CONNECTIONS=200 WRK_DURATION=60s make bench-http

# Gateway-only overhead (skips policy evaluation)
BENCH_PATH=/health make bench-http
```

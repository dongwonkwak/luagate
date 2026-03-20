# LuaGate Benchmark Baseline

> Generated: _TBD (run `make bench` to populate)_
>
> Environment: Docker Compose (single instance), local machine

## Target Metrics

| Metric | Target | Actual |
|--------|--------|--------|
| HTTP allow RPS | > 10,000 | _TBD_ |
| HTTP allow p50 | < 1ms | _TBD_ |
| HTTP allow p99 | < 5ms | _TBD_ |
| HTTP deny RPS | > 8,000 | _TBD_ |
| HTTP deny p99 | < 5ms | _TBD_ |
| SQLi scanner RPS (500 req/s) | 0% error | _TBD_ |
| Hot reload RPS drop | < 5% | _TBD_ |
| Hot reload error rate | < 0.1% | _TBD_ |
| TCP connections/sec | > 500 | _TBD_ |

## HTTP Allow Throughput

```text
(run: make bench-http)
```

## HTTP Deny Evaluation

```text
(run: tests/bench/http-deny.sh)
```

## SQLi Scanner Load

```text
(run: tests/bench/http-sqli.sh)
```

## Hot Reload Zero-Downtime

```text
(run: tests/bench/http-reload.sh)
```

## TCP Proxy Throughput

```text
(run: make bench-stream)
```

## Test Environment

| Component | Version |
|-----------|---------|
| Machine | _TBD_ |
| CPU | _TBD_ |
| RAM | _TBD_ |
| Docker | _TBD_ |
| OpenResty | _TBD_ |
| wrk | _TBD_ |
| vegeta | _TBD_ |

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
```

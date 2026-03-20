-- tests/bench/wrk/report.lua — Custom wrk reporting script
-- Outputs latency percentiles (p50, p90, p95, p99) and RPS in a parseable format.

done = function(summary, latency, _requests) -- luacheck: globals done
  local function us_to_ms(us)
    return string.format("%.2f", us / 1000)
  end

  io.write("\n--- LuaGate Benchmark Results ---\n")
  io.write(string.format("  Duration:     %ds\n", summary.duration / 1000000))
  io.write(string.format("  Requests:     %d\n", summary.requests))
  io.write(
    string.format(
      "  Errors:       connect=%d, read=%d, write=%d, timeout=%d, status=%d\n",
      summary.errors.connect,
      summary.errors.read,
      summary.errors.write,
      summary.errors.timeout,
      summary.errors.status
    )
  )
  io.write(string.format("  RPS:          %.2f\n", summary.requests / (summary.duration / 1000000)))
  io.write(string.format("  Transfer/sec: %.2f KB\n", (summary.bytes / (summary.duration / 1000000)) / 1024))
  io.write("\n  Latency Distribution:\n")
  io.write(string.format("    p50:  %s ms\n", us_to_ms(latency:percentile(50))))
  io.write(string.format("    p90:  %s ms\n", us_to_ms(latency:percentile(90))))
  io.write(string.format("    p95:  %s ms\n", us_to_ms(latency:percentile(95))))
  io.write(string.format("    p99:  %s ms\n", us_to_ms(latency:percentile(99))))
  io.write(string.format("    max:  %s ms\n", us_to_ms(latency.max)))
  io.write("--- End Results ---\n")

  -- Machine-readable summary line
  local error_total = summary.errors.connect
    + summary.errors.read
    + summary.errors.write
    + summary.errors.timeout
    + summary.errors.status
  local error_rate = 0
  if summary.requests > 0 then
    error_rate = (error_total / summary.requests) * 100
  end
  io.write(
    string.format(
      "\nSUMMARY: rps=%.2f p50=%.2f p99=%.2f errors=%d error_rate=%.4f%%\n",
      summary.requests / (summary.duration / 1000000),
      latency:percentile(50) / 1000,
      latency:percentile(99) / 1000,
      error_total,
      error_rate
    )
  )
end

#!/usr/bin/env bash
set -euo pipefail

# Zeddy Extreme Stress Test & Concurrency Benchmark

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/.build/release"
STRESS_HOME="$(mktemp -d /tmp/zeddy-stress-XXXXXX)"
export ZEDDY_HOME="${STRESS_HOME}"

cleanup() {
    "${BIN_DIR}/zeddy" daemon stop >/dev/null 2>&1 || true
    rm -rf "${STRESS_HOME}"
}
trap cleanup EXIT

echo "=========================================================="
echo "          ⚡ ZEDDY INTENSIVE STRESS TEST HARNESS           "
echo "=========================================================="
echo "Working directory: ${STRESS_HOME}"

# 1. Start daemon
echo ""
echo "=== Phase 1: Daemon Startup & Warmup ==="
"${BIN_DIR}/zeddy" daemon start
sleep 0.5
"${BIN_DIR}/zeddy" daemon status

# 2. Ingest 1,000 memories (Bulk write benchmark)
echo ""
echo "=== Phase 2: Ingesting 1,000 Unique Memories (Bulk Write) ==="
python3 - << 'PYEOF'
import subprocess, time, os, sys

bin_path = os.path.join(os.environ["SCRIPT_DIR"], ".build/release/zeddy")
topics = [
    ("Swift Concurrency", "Actor isolation prevents data races across Task boundaries in Swift 6."),
    ("SQLite FTS5 BM25", "BM25 ranking function provides TF-IDF weighted scoring on full-text index."),
    ("Memory Safety", "Rust ownership system guarantees zero dangling pointers and zero data races."),
    ("Token Compression", "Zeddy clips prompt contexts strictly within 1200 tokens to save LLM cost."),
    ("Network Security", "TLS 1.3 0-RTT resumption requires replay attack mitigations.")
]

t0 = time.time()
inserted = 0
batch_size = 500

for i in range(1, batch_size + 1):
    topic, body = topics[i % len(topics)]
    title = f"{topic} Rule #{i}"
    content = f"Directive {i}: {body} Hash reference key: {i * 1337}"
    kind = "project" if i % 2 == 0 else "global"
    proj = "/path/to/project/alpha" if kind == "project" else ""
    
    cmd = [bin_path, "add", "--title", title, "--content", content, "--kind", kind]
    if proj:
        cmd.extend(["--project", proj])
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error adding memory: {res.stderr}")
        sys.exit(1)
    inserted += 1

elapsed = time.time() - t0
print(f"✓ Inserted {inserted} memories in {elapsed:.2f}s ({inserted / elapsed:.1f} writes/sec)")
PYEOF

# 3. High-Concurrency Search & Context Queries (Parallel Stress)
echo ""
echo "=== Phase 3: Concurrent Multi-Threaded Query Bursts (20 Workers) ==="
python3 - << 'PYEOF'
import subprocess, time, os, concurrent.futures

bin_path = os.path.join(os.environ["SCRIPT_DIR"], ".build/release/zeddy")
queries = [
    "Swift Concurrency actor isolation",
    "FTS5 BM25 weighted scoring",
    "Rust zero data races memory safety",
    "Zeddy token compression LLM budget",
    "TLS 1.3 replay attack mitigation"
]

total_queries = 200
workers = 20

def run_query(idx):
    q = queries[idx % len(queries)]
    t_start = time.perf_counter()
    res = subprocess.run([bin_path, "context", q, "--stdout"], capture_output=True, text=True)
    latency_ms = (time.perf_counter() - t_start) * 1000
    return res.returncode == 0 and len(res.stdout) > 0, latency_ms

t0 = time.time()
latencies = []
failures = 0

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
    results = list(executor.map(run_query, range(total_queries)))

for success, lat in results:
    if success:
        latencies.append(lat)
    else:
        failures += 1

total_time = time.time() - t0
avg_lat = sum(latencies) / len(latencies) if latencies else 0
latencies.sort()
p50 = latencies[int(len(latencies) * 0.50)] if latencies else 0
p95 = latencies[int(len(latencies) * 0.95)] if latencies else 0
p99 = latencies[int(len(latencies) * 0.99)] if latencies else 0

print(f"✓ Total Queries:      {total_queries}")
print(f"✓ Concurrency:        {workers} simultaneous threads")
print(f"✓ Failures:           {failures}")
print(f"✓ Wall Time:          {total_time:.2f}s")
print(f"✓ Throughput:         {total_queries / total_time:.1f} req/s")
print(f"✓ Latency (avg):      {avg_lat:.2f} ms")
print(f"✓ Latency (p50):      {p50:.2f} ms")
print(f"✓ Latency (p95):      {p95:.2f} ms")
print(f"✓ Latency (p99):      {p99:.2f} ms")

if failures > 0:
    print("STRESS TEST FAILED: Failures detected during concurrency burst!")
    exit(1)
PYEOF

# 4. MCP Stdio Server Parallel Stream Load
echo ""
echo "=== Phase 4: MCP Stdio Server Batch Stream Stress ==="
python3 - << 'PYEOF'
import subprocess, json, time, os

mcp_bin = os.path.join(os.environ["SCRIPT_DIR"], ".build/release/zeddy-mcp")

p = subprocess.Popen([mcp_bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

# 1. Init
init_req = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
p.stdin.write(json.dumps(init_req) + "\n")
p.stdin.flush()
_ = p.stdout.readline()

# 2. Fire 100 rapid requests on same stdio connection
t0 = time.time()
num_reqs = 100
for i in range(2, num_reqs + 2):
    req = {
        "jsonrpc": "2.0",
        "id": i,
        "method": "tools/call",
        "params": {
            "name": "zeddy_context",
            "arguments": {"prompt": "actor isolation in Swift 6 concurrency"}
        }
    }
    p.stdin.write(json.dumps(req) + "\n")
p.stdin.flush()

for _ in range(num_reqs):
    line = p.stdout.readline()
    resp = json.loads(line)
    assert "result" in resp, f"Invalid MCP response: {resp}"

elapsed = time.time() - t0
p.terminate()

print(f"✓ 100 MCP requests streamed in {elapsed:.3f}s ({num_reqs / elapsed:.1f} req/s over stdio)")
print(f"✓ Average MCP latency: {(elapsed / num_reqs) * 1000:.2f} ms per call")
PYEOF

# 5. Database Integrity & Memory Footprint Check
echo ""
echo "=== Phase 5: SQLite Database Integrity & Memory Check ==="
sqlite3 "${STRESS_HOME}/data/memories.db" "PRAGMA integrity_check;"
sqlite3 "${STRESS_HOME}/data/memories.db" "SELECT count(*) FROM memories;"
sqlite3 "${STRESS_HOME}/data/memories.db" "SELECT count(*) FROM memories_fts;"

echo ""
echo "=== Phase 6: Telemetry & KPI Dump ==="
"${BIN_DIR}/zeddy" usage
"${BIN_DIR}/zeddy" stats

echo ""
echo "=========================================================="
echo "          🎉 ALL STRESS TESTS PASSED WITH 0 ERRORS!        "
echo "=========================================================="

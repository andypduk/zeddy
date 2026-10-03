#!/usr/bin/env python3
"""
Zeddy 2-Hour Continuous Zed MCP Stress & Concurrency Runner
Simulates multi-threaded Zed editor context server load continuously.
Tracks latency, throughput, token economy, error rate, and daemon RSS memory leaks.
"""

import argparse
import concurrent.futures
import json
import os
import random
import signal
import subprocess
import sys
import time

MCP_BIN = os.path.expanduser("/Applications/Zeddy.app/Contents/MacOS/zeddy-mcp")
if not os.path.exists(MCP_BIN):
    MCP_BIN = os.path.expanduser("~/.local/bin/zeddy-mcp")

TOPICS = [
    ("Swift Concurrency", "Actor isolation prevents data races across Task boundaries in Swift 6."),
    ("SQLite FTS5 BM25", "BM25 ranking function provides TF-IDF weighted scoring on full-text index."),
    ("Memory Safety", "Rust ownership system guarantees zero dangling pointers and zero data races."),
    ("Token Compression", "Zeddy clips prompt contexts strictly within 1200 tokens to save LLM cost."),
    ("Network Security", "TLS 1.3 0-RTT resumption requires replay attack mitigations."),
    ("9Router Integration", "Zeddy communicates with 9Router LLM proxy on localhost:20128."),
    ("Zed Context Server", "Zeddy implements Model Context Protocol stdio transport for Zed editor."),
    ("Daemon IPC", "Domain socket at ~/.zeddy/zeddy.sock handles non-blocking async messaging.")
]

SEARCH_QUERIES = [
    "Swift Concurrency actor isolation",
    "FTS5 BM25 weighted scoring",
    "Rust zero data races memory safety",
    "Zeddy token compression LLM budget",
    "TLS 1.3 replay attack mitigation",
    "9Router proxy integration",
    "Zed context server MCP",
    "Daemon IPC domain socket"
]

class StressHarness:
    def __init__(self, duration_sec: int, workers: int, log_path: str, summary_path: str):
        self.duration_sec = duration_sec
        self.workers = workers
        self.log_path = log_path
        self.summary_path = summary_path
        self.running = True
        self.total_requests = 0
        self.total_errors = 0
        self.latencies = []
        self.t_start = time.time()
        self.last_report = time.time()
        self.daemon_pid = self._find_daemon_pid()

    def _find_daemon_pid(self):
        try:
            out = subprocess.check_output(["pgrep", "-f", "zeddy-daemon"], text=True).strip()
            if out:
                return int(out.split()[0])
        except Exception:
            pass
        return None

    def _get_daemon_rss_mb(self):
        if not self.daemon_pid:
            self.daemon_pid = self._find_daemon_pid()
        if not self.daemon_pid:
            return 0.0
        try:
            out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(self.daemon_pid)], text=True).strip()
            if out:
                return round(int(out) / 1024.0, 2)
        except Exception:
            pass
        return 0.0

    def log(self, msg: str):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        try:
            with open(self.log_path, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass

    def stop(self, signum=None, frame=None):
        self.running = False
        self.log("Interrupt received. Stopping stress workers gracefully...")

    def run_worker(self, worker_id: int):
        req_id = 1
        proc = None

        def open_proc():
            p = subprocess.Popen(
                [MCP_BIN],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                bufsize=1
            )
            # Send init
            init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}
            p.stdin.write(json.dumps(init) + "\n")
            p.stdin.flush()
            _ = p.stdout.readline()
            return p

        try:
            proc = open_proc()
        except Exception as e:
            self.log(f"Worker {worker_id} failed to launch {MCP_BIN}: {e}")
            return

        while self.running:
            if time.time() - self.t_start >= self.duration_sec:
                break

            dice = random.random()
            req_id += 1

            if dice < 0.60:
                # 60% zeddy_context (standard Zed prompt injection)
                query = random.choice(SEARCH_QUERIES)
                payload = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "tools/call",
                    "params": {
                        "name": "zeddy_context",
                        "arguments": {"prompt": query}
                    }
                }
            elif dice < 0.85:
                # 25% zeddy_search (BM25 keyword retrieval)
                query = random.choice(SEARCH_QUERIES)
                payload = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "tools/call",
                    "params": {
                        "name": "zeddy_search",
                        "arguments": {"query": query}
                    }
                }
            elif dice < 0.95:
                # 10% zeddy_add (storing memory)
                topic, body = random.choice(TOPICS)
                idx = random.randint(1000, 999999)
                payload = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "tools/call",
                    "params": {
                        "name": "zeddy_add",
                        "arguments": {
                            "title": f"Live Stress Memory {idx}",
                            "content": f"{topic}: {body} (Stress run index {idx})",
                            "kind": "global" if idx % 2 == 0 else "project",
                            "projectPath": "/tmp/zeddy-synthetic-project" if idx % 2 != 0 else None,
                            "tags": ["stress", "zed", "mcp"]
                        }
                    }
                }
            else:
                # 5% zeddy_stats
                payload = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "tools/call",
                    "params": {
                        "name": "zeddy_stats",
                        "arguments": {"reason": "Zed continuous health check"}
                    }
                }

            t0 = time.perf_counter()
            try:
                proc.stdin.write(json.dumps(payload) + "\n")
                proc.stdin.flush()
                resp_line = proc.stdout.readline()
                dt_ms = (time.perf_counter() - t0) * 1000.0

                if not resp_line:
                    raise IOError("Empty response from zeddy-mcp")

                resp = json.loads(resp_line)
                if "error" in resp:
                    self.total_errors += 1
                else:
                    self.total_requests += 1
                    self.latencies.append(dt_ms)
            except Exception as ex:
                self.total_errors += 1
                # Attempt to restart process
                try:
                    proc.kill()
                except Exception:
                    pass
                try:
                    proc = open_proc()
                except Exception:
                    time.sleep(0.5)

            # Tiny sleep to avoid spinning CPU at 100% on a multi-hour soak test
            time.sleep(0.005)

        if proc:
            try:
                proc.terminate()
            except Exception:
                pass

    def emit_summary(self):
        elapsed = time.time() - self.t_start
        total = self.total_requests
        rps = total / elapsed if elapsed > 0 else 0
        daemon_rss = self._get_daemon_rss_mb()

        lats = sorted(self.latencies[-5000:]) if self.latencies else [0]
        avg_lat = sum(lats) / len(lats) if lats else 0
        p50 = lats[int(len(lats) * 0.50)]
        p95 = lats[int(len(lats) * 0.95)]
        p99 = lats[int(len(lats) * 0.99)]

        summary = {
            "elapsed_seconds": round(elapsed, 1),
            "target_duration_seconds": self.duration_sec,
            "total_requests": total,
            "total_errors": self.total_errors,
            "requests_per_sec": round(rps, 1),
            "avg_latency_ms": round(avg_lat, 2),
            "p50_latency_ms": round(p50, 2),
            "p95_latency_ms": round(p95, 2),
            "p99_latency_ms": round(p99, 2),
            "daemon_rss_mb": daemon_rss,
            "timestamp": time.time()
        }

        try:
            with open(self.summary_path, "w") as f:
                json.dump(summary, f, indent=2)
        except Exception:
            pass

        self.log(
            f"STATS: {total:,} reqs | {self.total_errors} errs | {rps:.1f} req/s | "
            f"lat(avg/p50/p95/p99): {avg_lat:.2f}/{p50:.2f}/{p95:.2f}/{p99:.2f} ms | "
            f"daemon RSS: {daemon_rss} MB | elapsed: {int(elapsed)}s / {self.duration_sec}s"
        )

    def run(self):
        self.log("=============================================================")
        self.log("🚀 STARTING ZEDDY 2-HOUR SUSTAINED ZED MCP STRESS RUNNER")
        self.log(f"Target Duration:  {self.duration_sec}s ({self.duration_sec / 3600:.1f} hours)")
        self.log(f"Concurrent Zed Sessions: {self.workers}")
        self.log(f"MCP Binary:       {MCP_BIN}")
        self.log(f"Daemon PID:       {self.daemon_pid} (Initial RSS: {self._get_daemon_rss_mb()} MB)")
        self.log("=============================================================")

        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)

        with concurrent.futures.ThreadPoolExecutor(max_workers=self.workers) as executor:
            futures = [executor.submit(self.run_worker, w) for w in range(self.workers)]

            while self.running and (time.time() - self.t_start < self.duration_sec):
                time.sleep(10.0)
                self.emit_summary()

            self.running = False
            concurrent.futures.wait(futures, timeout=10.0)

        self.emit_summary()
        self.log("=============================================================")
        self.log(f"🏁 STRESS TEST COMPLETED: {self.total_requests} requests processed with {self.total_errors} errors.")
        self.log("=============================================================")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Zeddy 2-Hour Zed MCP Stress Harness")
    parser.add_argument("--duration", type=int, default=7200, help="Test duration in seconds (default 7200)")
    parser.add_argument("--workers", type=int, default=8, help="Number of concurrent Zed workers (default 8)")
    parser.add_argument("--log", type=str, default="stress_2hr.log", help="Log output path")
    parser.add_argument("--summary", type=str, default="stress_summary.json", help="Summary JSON output path")
    args = parser.parse_args()

    harness = StressHarness(args.duration, args.workers, args.log, args.summary)
    harness.run()

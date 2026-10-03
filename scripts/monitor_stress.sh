#!/usr/bin/env bash
# Quick monitor for 2-hour Zeddy stress test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Zeddy 2-Hour Stress Test Status ==="
if [ -f "${ROOT_DIR}/stress_summary.json" ]; then
    cat "${ROOT_DIR}/stress_summary.json"
    echo ""
fi

if [ -f "${ROOT_DIR}/stress_2hr.log" ]; then
    echo "--- Recent Log Tail ---"
    tail -n 10 "${ROOT_DIR}/stress_2hr.log"
    echo ""
fi

echo "--- Zeddy Usage & Throughput ---"
~/.local/bin/zeddy usage

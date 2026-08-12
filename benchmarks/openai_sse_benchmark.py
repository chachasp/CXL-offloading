#!/usr/bin/env python3
"""Dependency-free streaming benchmark for an OpenAI-compatible chat endpoint."""

from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import json
import math
import statistics
import time
import urllib.parse
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class Result:
    ok: bool
    status: int
    ttft_s: float | None
    itl_s: list[float]
    latency_s: float
    output_tokens: int
    error: str | None = None


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * p
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] * (high - position) + ordered[high] * (position - low)


def one_request(base_url: str, model: str, prompt: str, max_tokens: int, timeout: int) -> Result:
    parsed = urllib.parse.urlparse(base_url)
    connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    connection = connection_class(parsed.hostname, parsed.port, timeout=timeout)
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": max_tokens,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
    )
    start = time.perf_counter()
    first = None
    previous = None
    intervals: list[float] = []
    output_tokens = 0
    try:
        connection.request(
            "POST",
            (parsed.path.rstrip("/") if parsed.path else "") + "/v1/chat/completions",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        if response.status != 200:
            error = response.read(2048).decode(errors="replace")
            return Result(False, response.status, None, [], time.perf_counter() - start, 0, error)
        while True:
            line = response.readline()
            if not line:
                break
            line = line.decode("utf-8", errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            event = json.loads(data)
            usage = event.get("usage") or {}
            if usage.get("completion_tokens") is not None:
                output_tokens = int(usage["completion_tokens"])
            choices = event.get("choices") or []
            delta = choices[0].get("delta", {}) if choices else {}
            if delta.get("content"):
                now = time.perf_counter()
                if first is None:
                    first = now
                elif previous is not None:
                    intervals.append(now - previous)
                previous = now
        end = time.perf_counter()
        return Result(True, 200, None if first is None else first - start, intervals, end - start, output_tokens)
    except Exception as error:
        return Result(False, 0, None, [], time.perf_counter() - start, 0, repr(error))
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default="Qwen/Qwen3-30B-A3B-FP8")
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--requests", type=int, default=100)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--output", default="results/benchmark.json")
    args = parser.parse_args()
    prompts = [line.strip() for line in open(args.prompt_file, encoding="utf-8") if line.strip()]
    if not prompts:
        parser.error("prompt file is empty")

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [
            pool.submit(one_request, args.url, args.model, prompts[i % len(prompts)], args.max_tokens, args.timeout)
            for i in range(args.requests)
        ]
        results = [future.result() for future in futures]
    elapsed = time.perf_counter() - started
    good = [result for result in results if result.ok]
    ttfts = [result.ttft_s for result in good if result.ttft_s is not None]
    itls = [value for result in good for value in result.itl_s]
    output_tokens = sum(result.output_tokens for result in good)
    summary = {
        "requests": args.requests,
        "successful": len(good),
        "errors": len(results) - len(good),
        "elapsed_s": elapsed,
        "successful_requests_per_s": len(good) / elapsed,
        "output_tokens_per_s": output_tokens / elapsed,
        "ttft_p50_s": percentile(ttfts, 0.50),
        "ttft_p99_s": percentile(ttfts, 0.99),
        "itl_p50_s": percentile(itls, 0.50),
        "itl_p99_s": percentile(itls, 0.99),
        "latency_mean_s": statistics.mean([result.latency_s for result in good]) if good else None,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps({"summary": summary, "results": [asdict(result) for result in results]}, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2))
    print(f"output={output}")
    return 0 if len(good) == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

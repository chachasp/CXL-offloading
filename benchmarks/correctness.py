#!/usr/bin/env python3
"""Compare deterministic OpenAI-compatible responses from two endpoints."""

from __future__ import annotations

import argparse
import json
import urllib.request


def request(url: str, model: str, prompt: str, timeout: int) -> dict:
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "seed": 1234,
            "max_tokens": 128,
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def content(response: dict) -> str:
    return response["choices"][0]["message"]["content"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-url", required=True)
    parser.add_argument("--cxl-url", required=True)
    parser.add_argument("--model", default="Qwen/Qwen3-30B-A3B-FP8")
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--output", default="results/correctness.json")
    args = parser.parse_args()

    prompts = [line.strip() for line in open(args.prompt_file, encoding="utf-8") if line.strip()]
    results = []
    passed = True
    for index, prompt in enumerate(prompts):
        baseline = request(args.baseline_url, args.model, prompt, args.timeout)
        cxl = request(args.cxl_url, args.model, prompt, args.timeout)
        equal = content(baseline) == content(cxl)
        passed &= equal
        results.append(
            {
                "index": index,
                "equal": equal,
                "baseline": content(baseline),
                "cxl": content(cxl),
                "baseline_usage": baseline.get("usage"),
                "cxl_usage": cxl.get("usage"),
            }
        )
    from pathlib import Path

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"passed": passed, "results": results}, ensure_ascii=False, indent=2))
    print(f"RESULT: {'PASS' if passed else 'FAIL'} output={output}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
import argparse
import concurrent.futures
import json
import statistics
import time
import urllib.error
import urllib.request

WORDS = (
    "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu "
    "nu xi omicron pi rho sigma tau upsilon phi chi psi omega"
).split()

def build_prefix(word_count, salt, fixed_word_offset):
    offset = (
        fixed_word_offset
        if fixed_word_offset is not None
        else sum(salt.encode()) % len(WORDS)
    )
    words = [
        WORDS[(offset + i * 7 + i // len(WORDS)) % len(WORDS)]
        for i in range(word_count)
    ]
    return f"benchmark {salt} " + " ".join(words)

def run_one(url, model, prefix, index, timeout):
    body = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": f"{prefix}\n\nRequest {index}: reply with one word.",
        }],
        "max_tokens": 8,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": 0.0,
    }
    request = urllib.request.Request(
        f"{url}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    ttft = None
    prompt_tokens = None
    cached_tokens = None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw_line in response:
                line = raw_line.strip()
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if not payload or payload == b"[DONE]":
                    continue
                event = json.loads(payload)
                usage = event.get("usage") or {}
                if usage.get("prompt_tokens") is not None:
                    prompt_tokens = usage["prompt_tokens"]
                prompt_details = usage.get("prompt_tokens_details") or {}
                if prompt_details.get("cached_tokens") is not None:
                    cached_tokens = prompt_details["cached_tokens"]
                choices = event.get("choices") or []
                delta = choices[0].get("delta") if choices else {}
                delta = delta or {}
                if ttft is None and (
                    delta.get("content")
                    or delta.get("reasoning")
                    or delta.get("reasoning_content")
                ):
                    ttft = time.perf_counter() - started
            return {
                "index": index,
                "status": response.status,
                "ttft": ttft,
                "total": time.perf_counter() - started,
                "prompt_tokens": prompt_tokens,
                "cached_tokens": cached_tokens,
            }
    except urllib.error.HTTPError as error:
        return {
            "index": index,
            "status": error.code,
            "error": error.read(300).decode(errors="replace"),
        }
    except Exception as error:
        return {"index": index, "status": -1, "error": repr(error)}

def percentile(values, fraction):
    rank = min(len(values) - 1, int(len(values) * fraction))
    return sorted(values)[rank]

def summarize(mode, repetition, salt, results, wall, warmups):
    successful = [
        result for result in results
        if result.get("status") == 200 and result.get("ttft") is not None
    ]
    ttfts = [result["ttft"] for result in successful]
    totals = [result["total"] for result in successful]
    prompt_tokens = [
        result["prompt_tokens"] for result in successful
        if result.get("prompt_tokens") is not None
    ]
    cached_tokens = [
        result["cached_tokens"] for result in successful
        if result.get("cached_tokens") is not None
    ]
    summary = {
        "mode": mode,
        "repetition": repetition,
        "salt": salt,
        "requests": len(results),
        "ok": len(successful),
        "bad": len(results) - len(successful),
        "wall_seconds": wall,
        "requests_per_second": len(successful) / wall if wall else None,
        "prompt_tokens": statistics.median(prompt_tokens) if prompt_tokens else None,
        "cached_tokens_median": (
            statistics.median(cached_tokens) if cached_tokens else None
        ),
        "cached_tokens_positive": sum(
            value > 0 for value in cached_tokens
        ),
        "ttft_mean": statistics.mean(ttfts) if ttfts else None,
        "ttft_p50": percentile(ttfts, 0.50) if ttfts else None,
        "ttft_p90": percentile(ttfts, 0.90) if ttfts else None,
        "ttft_p99": percentile(ttfts, 0.99) if ttfts else None,
        "total_mean": statistics.mean(totals) if totals else None,
        "total_p90": percentile(totals, 0.90) if totals else None,
        "warmup_ttft": [result.get("ttft") for result in warmups],
    }
    print("SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    print("DETAIL " + json.dumps(sorted(results, key=lambda item: item["index"])), flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True)
    parser.add_argument("--repetition", type=int, required=True)
    parser.add_argument("--salt", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", default="zai-org/GLM-5.2-FP8")
    parser.add_argument("--concurrency", type=int, default=12)
    parser.add_argument("--requests", type=int, default=48)
    parser.add_argument("--prefix-words", type=int, default=60000)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--fixed-word-offset", type=int)
    args = parser.parse_args()

    prefix = build_prefix(
        args.prefix_words,
        args.salt,
        args.fixed_word_offset,
    )
    print(json.dumps({
        "mode": args.mode,
        "repetition": args.repetition,
        "salt": args.salt,
        "prefix_words": args.prefix_words,
        "prefix_characters": len(prefix),
        "requests": args.requests,
        "concurrency": args.concurrency,
        "warmup": args.warmup,
    }, sort_keys=True), flush=True)

    warmups = [
        run_one(args.url, args.model, prefix, -1 - index, args.timeout)
        for index in range(args.warmup)
    ]
    print("WARMUP " + json.dumps(warmups, sort_keys=True), flush=True)

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.concurrency
    ) as executor:
        futures = [
            executor.submit(
                run_one,
                args.url,
                args.model,
                prefix,
                index,
                args.timeout,
            )
            for index in range(args.requests)
        ]
        results = [future.result() for future in futures]
    wall = time.perf_counter() - started
    summarize(
        args.mode,
        args.repetition,
        args.salt,
        results,
        wall,
        warmups,
    )

if __name__ == "__main__":
    main()

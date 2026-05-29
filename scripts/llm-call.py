#!/usr/bin/env python3
"""
Call the Anthropic API with a prompt, print the response to stdout, and write real
token counts to the ledger. Requires ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN.

Usage:
  python3 scripts/llm-call.py --model claude-opus-4-8 --prompt-file P \
    --exp-id EXP-001 --phase select-propose --agent-id opus --ledger experiments/token-ledger.tsv

Output: stdout = model response; stderr = ## progress; ledger += one TSV row
  (exp_id, phase, agent_id, model, tokens_in, tokens_out, cost_usd, timestamp, description)
"""
import argparse, os, sys, time
from datetime import datetime


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--prompt-file", required=True)
    p.add_argument("--exp-id", default="EXP-000")
    p.add_argument("--phase", default="unknown")
    p.add_argument("--agent-id", default="agent")
    p.add_argument("--ledger", required=True)
    p.add_argument("--description", default="")
    p.add_argument("--max-tokens", type=int, default=4096)
    args = p.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    oauth = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if not api_key and not oauth:
        print("## ERROR: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN", file=sys.stderr)
        print("##   CLAUDE_CODE_OAUTH_TOKEN — run `claude setup-token`", file=sys.stderr)
        sys.exit(1)

    with open(args.prompt_file) as f:
        prompt = f.read()

    import anthropic
    if api_key:
        client = anthropic.Anthropic(api_key=api_key)
    else:
        client = anthropic.Anthropic(api_key="oauth",
                                     default_headers={"Authorization": f"Bearer {oauth}"})

    print(f"## Calling {args.model} ({args.phase} / {args.agent_id})...", file=sys.stderr)
    t0 = time.time()
    message = client.messages.create(
        model=args.model, max_tokens=args.max_tokens,
        messages=[{"role": "user", "content": prompt}],
    )
    elapsed = time.time() - t0
    tin, tout = message.usage.input_tokens, message.usage.output_tokens

    # Prices per MTok (input, output), approximate as of 2026-05.
    PRICES = {
        "claude-opus-4-8":           (15.0, 75.0),
        "claude-sonnet-4-6":         (3.0,  15.0),
        "claude-haiku-4-5-20251001": (0.8,   4.0),
    }
    pin, pout = PRICES.get(args.model, (3.0, 15.0))
    cost = (tin * pin + tout * pout) / 1_000_000
    print(f"## Done in {elapsed:.1f}s — in={tin} out={tout} cost=${cost:.4f}", file=sys.stderr)

    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    row = "\t".join([args.exp_id, args.phase, args.agent_id, args.model,
                     str(tin), str(tout), f"{cost:.6f}", ts, args.description])
    with open(args.ledger, "a") as f:
        f.write(row + "\n")

    print(message.content[0].text)


if __name__ == "__main__":
    main()

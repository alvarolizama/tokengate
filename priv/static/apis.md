# TokenGate API

OpenAI-compatible gateway. Every endpoint below lives under `/v1` and
authenticates with a bearer API key:

```
Authorization: Bearer <API_KEY>
```

Base URL: `https://<your-tokengate-host>/v1`. Requests and responses are JSON
except where noted. Every **successful** response carries the real provider
cost in `X-Tokengate-Cost` (USD); a cache hit reports `X-Tokengate-Cost: 0`
and `X-Tokengate-Cache: hit`.

## GET /v1/models

Lists the models your grants allow.

```json
{"data": [{"id": "jev-latest", "object": "model", "model_type": "decision", "context_window": 128000}]}
```

## POST /v1/chat/completions

Standard OpenAI chat shape. Supports `stream: true` (SSE, with a cost frame
before `data: [DONE]`), tool calling, and reasoning knobs — the gateway
reshapes them to whatever the routed upstream documents.

## POST /v1/embeddings

Standard OpenAI embeddings shape: `{"model": "...", "input": "text"}`.

## POST /v1/decisions

Typed decisions in the OpenAI Decisions shape. Send `input` (a string, or an
ordered array of messages with `input_text` / `input_json` parts) and a
non-empty array of typed questions; answers come back in question order.

```json
{
  "model": "jev-latest",
  "input": "Customer message: I was charged twice for my order.",
  "questions": [
    {"type": "predicate", "name": "angry", "instructions": "Is the customer angry?"},
    {"type": "choice", "name": "route", "instructions": "Which team?",
     "choices": [{"value": "billing"}, {"value": "technical"}]},
    {"type": "score", "name": "urgency", "instructions": "How urgent?",
     "levels": [{"label": "low"}, {"label": "high"}]}
  ]
}
```

```json
{
  "answers": [
    {"type": "predicate", "name": "angry", "probability": 0.63},
    {"type": "choice", "name": "route", "choice": "billing",
     "probabilities": [{"value": "billing", "probability": 0.99}], "confidence": 0.99},
    {"type": "score", "name": "urgency", "score": 1.2,
     "probabilities": [{"value": "low", "probability": 0.8}], "confidence": 0.6}
  ],
  "usage": {"input_tokens": 239, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0}}
}
```

- `predicate` answers with the probability that the statement is true.
- `choice` picks one `value` and returns per-option probabilities.
- `score` returns the probability-weighted level index plus per-level
  probabilities (the level index is 0-based, lowest level first).

The gateway routes to whichever configured provider serves the model and
translates the wire when the upstream speaks the TypeSafe System One shape
(`/systemone`) instead of the OpenAI shape — one request shape for OpenAI,
Fireworks, TypeSafe, OpenRouter and local engines alike. Only `decision`
models are reachable from this endpoint; image inputs (`input_image` parts)
are rejected for System One providers (TypeSafe's asset flow) and pass
through untouched for OpenAI-shape providers that support them.

## Path-routed services

`POST /v1/audio/transcriptions` (multipart audio → text),
`POST /v1/audio/speech` (text → audio bytes),
`POST /v1/images/generations` (OpenAI image shape). Each endpoint serves only
models registered with its type (`stt`, `tts`, `image`).

## Errors

Errors carry `{"error": {"code": ..., "message": ...}}`:

| HTTP | `code` |
| --- | --- |
| 401 | `missing_api_key`, `invalid_api_key` |
| 403 | `membership_inactive` |
| 400 | `invalid_request`, `model_type_mismatch` |
| 402 | `budget_exceeded` |
| 404 | `model_not_found` |
| 429 | `rate_limited`, `concurrency_exceeded`, `provider_concurrency_exceeded` |
| 503 | `no_providers`, `no_available_provider`, `cascade_exhausted`, `all_providers_down` |

A 429 for `rate_limited` / `provider_rate_limited` includes `Retry-After`
(seconds). A 4xx from the upstream (payload rejected) surfaces with the
upstream's own status and `upstream_client_error`.

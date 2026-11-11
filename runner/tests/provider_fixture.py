"""Deterministic protocol peer. Never imports or calls a real coding provider."""
import json
import os
import sys
import time

provider = os.environ["REPRISE_TEST_PROVIDER"]
now = time.time()
if "usage" in sys.argv:
    print(json.dumps({"weekly": {"used_percentage": 10, "resets_at": now + 86400, "windowDurationMins": 10080}}))
    sys.exit(0)

def send(value):
    print(json.dumps(value), flush=True)

def options():
    return {"configOptions": [
        {"id": "model", "options": [{"value": "grok-test-strong", "name": "Strong"}, {"value": "grok-test-frontier", "name": "Frontier"}]},
        {"id": "reasoning_effort", "options": [{"value": e, "name": e} for e in ("low", "medium", "high")]}
    ]}

for line in sys.stdin:
    packet = json.loads(line)
    with open(os.environ["REPRISE_TEST_TRACE"], "a", encoding="utf-8") as trace:
        trace.write(json.dumps(packet) + "\n")
    method = packet.get("method", "")
    params = packet.get("params", {})
    if "id" not in packet:
        continue
    if method == "initialize":
        result = {"agentCapabilities": {"loadSession": True}}
    elif method == "model/list":
        result = {"data": [{"model": name, "displayName": name, "supportedReasoningEfforts": [{"reasoningEffort": e} for e in ("low", "medium", "high")]} for name in ("gpt-test-sol", "gpt-test-astra")]}
    elif method == "account/rateLimits/read":
        result = {"rateLimitsByLimitId": {"codex": {"planType": "plus", "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": now + 7200}, "secondary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": now + 86400}}}}
    elif method == "thread/resume":
        result = {"thread": {"id": params["threadId"], "status": {"type": "idle"}}}
    elif method in ("session/load", "session/set_config_option"):
        result = options()
    elif method == "turn/start":
        result = {"turn": {"id": "fixture-turn"}}
    elif method == "session/prompt":
        send({"method": "session/update", "params": {"sessionId": params["sessionId"], "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Fixture response."}}}})
        result = {"stopReason": "end_turn"}
    else:
        send({"id": packet["id"], "error": {"code": -32601, "message": "Unexpected fixture request"}})
        continue
    send({"id": packet["id"], "result": result})
    if method == "turn/start":
        send({"method": "item/agentMessage/delta", "params": {"threadId": params["threadId"], "delta": "Fixture response."}})
        send({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": "fixture-turn", "status": "completed"}}})

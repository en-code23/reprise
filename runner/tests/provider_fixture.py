"""Deterministic protocol peer. Never imports or calls a real coding provider."""
import json
import os
import sys
import time
import threading

provider = os.environ["REPRISE_TEST_PROVIDER"]
failed = os.environ.get("REPRISE_TEST_OUTCOME") == "failed"
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
    if packet.get("type") == "control_request":
        request = packet["request"]
        if request["subtype"] == "initialize":
            result = {"models": [{"value": model, "resolvedModel": "claude-" + model + "-5-5", "displayName": model, "supportedEffortLevels": ["low", "medium", "high"]} for model in ("haiku", "sonnet", "opus")]}
        else:
            result = {}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": packet["request_id"], "response": result}})
        continue
    if packet.get("type") == "user":
        if os.environ.get("REPRISE_TEST_BACKGROUND") == "1":
            send({"type": "system", "subtype": "task_started", "task_id": "background-1"})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Fixture response."}}})
        send({"type": "result", "subtype": "error_during_execution" if failed else "success", "session_id": packet["session_id"], "is_error": failed})
        if os.environ.get("REPRISE_TEST_BACKGROUND") == "1":
            def finish_background():
                time.sleep(0.1)
                send({"type": "system", "subtype": "task_notification", "task_id": "background-1", "status": "completed"})
            threading.Thread(target=finish_background, daemon=True).start()
        continue
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
        result = {"stopReason": "cancelled" if failed else "end_turn"}
    else:
        send({"id": packet["id"], "error": {"code": -32601, "message": "Unexpected fixture request"}})
        continue
    send({"id": packet["id"], "result": result})
    if method == "turn/start":
        send({"method": "item/agentMessage/delta", "params": {"threadId": params["threadId"], "delta": "Fixture response."}})
        send({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": "fixture-turn", "status": "failed" if failed else "completed"}}})

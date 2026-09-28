"""Resolve a boss's exact ExternalBehaviorTree closure without persisting raw keys."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any


class PipelineError(Exception):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise PipelineError(code)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def walk(value: Any, state: dict[str, Any]) -> None:
    if isinstance(value, dict):
        if isinstance(value.get("Type"), str):
            state["node_count"] += 1
            state["task_types"].append(value["Type"])
            if value.get("Disabled") is True:
                state["disabled_node_count"] += 1
            # QTE use is decided by the tree: a QuickTimeEvent* task, not a table row.
            if value["Type"].rsplit(".", 1)[-1].startswith("QuickTimeEvent"):
                state["quick_time_event_node_count"] += 1
        for key, child in value.items():
            key_lower = key.lower()
            if "skillaninumber" in key_lower and isinstance(child, str):
                state["skill_animation_refs"].append(child)
            if "partslist" in key_lower and isinstance(child, list):
                state["part_refs"].extend(str(item) for item in child)
            if key_lower.endswith("point") or "pointindex" in key_lower:
                if isinstance(child, (str, int, float, bool)):
                    state["point_refs"].append(f"{key}={child}")
            walk(child, state)
    elif isinstance(value, list):
        for child in value:
            walk(child, state)


def string_set_summary(values: list[str]) -> dict[str, Any]:
    counts = collections.Counter(values)
    lines = [f"{key}\t{counts[key]}" for key in sorted(counts)]
    return {
        "referenceCount": sum(counts.values()),
        "distinctReferenceCount": len(counts),
        "canonicalSha256": sha256_bytes("\n".join(lines).encode("utf-8")),
    }


def aggregate_hash(values: list[str]) -> str:
    if len(values) == 1:
        return values[0]
    return sha256_bytes("\n".join(sorted(values)).encode("utf-8"))


def validate_graph(graph: Any) -> None:
    # Disabled children and detached editor tasks belong to the original asset.
    # Preserve them in the canonical hash; they do not invalidate an enabled root.
    root = graph.get("RootTask") if isinstance(graph, dict) else None
    require(
        isinstance(root, dict)
        and isinstance(root.get("Type"), str)
        and bool(root["Type"].strip())
        and root.get("Disabled", False) is False,
        "boss_behavior_graph_invalid",
    )


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    require(path.is_absolute() and not path.exists(), "boss_behavior_output_exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def run(args: argparse.Namespace) -> None:
    private_path = args.private_discovery.resolve()
    source_path = args.source_discovery.resolve()
    bundle_path = args.behavior_bundle.resolve()
    output_path = args.output.resolve()
    require(
        private_path.is_file() and source_path.is_file() and bundle_path.is_file(),
        "boss_behavior_input_missing",
    )
    private = json.loads(private_path.read_text(encoding="utf-8"))
    source = json.loads(source_path.read_text(encoding="utf-8"))
    require(
        private.get("contractId") == "nll/private-boss-content-diagnostic/v1"
        and source.get("contractId") == "nll/boss-content-discovery/v1"
        and private.get("seasonNumber") == source.get("seasonNumber"),
        "boss_behavior_discovery_invalid",
    )
    keys = sorted(set(private.get("behaviorKeys") or []))
    behavior = source.get("behaviorAssembly") or {}
    require(
        keys
        and len(keys) == behavior.get("rootReferenceCount")
        and sha256_bytes("\n".join(keys).encode("utf-8"))
        == behavior.get("rootReferenceSetSha256"),
        "boss_behavior_root_mismatch",
    )

    if args.unitypy_root:
        sys.path.insert(0, str(args.unitypy_root.resolve()))
    try:
        import UnityPy  # type: ignore
    except Exception as exception:
        raise PipelineError("boss_behavior_unitypy_unavailable") from exception

    environment = UnityPy.load(str(bundle_path))
    matches: dict[str, list[dict[str, Any]]] = {key: [] for key in keys}
    external_count = 0
    for obj in environment.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        data = obj.read()
        try:
            script = data.m_Script.read()
        except Exception:
            continue
        if getattr(script, "m_ClassName", None) != "ExternalBehaviorTree":
            continue
        external_count += 1
        name = getattr(data, "m_Name", None)
        if name not in matches:
            continue
        tree = obj.read_typetree()
        serialized = tree["mBehaviorSource"]["mTaskData"]["JSONSerialization"]
        graph = json.loads(serialized)
        validate_graph(graph)
        state: dict[str, Any] = {
            "node_count": 0,
            "disabled_node_count": 0,
            "quick_time_event_node_count": 0,
            "task_types": [],
            "skill_animation_refs": [],
            "part_refs": [],
            "point_refs": [],
        }
        walk(graph, state)
        matches[name].append(
            {
                "nodeCount": state["node_count"],
                "disabledNodeCount": state["disabled_node_count"],
                "quickTimeEventNodeCount": state["quick_time_event_node_count"],
                "canonicalGraphSha256": sha256_bytes(canonical_json(graph)),
                "taskTypeSet": string_set_summary(state["task_types"]),
                "skillAnimationReferenceSet": string_set_summary(
                    state["skill_animation_refs"]
                ),
                "partReferenceSet": string_set_summary(state["part_refs"]),
                "pointReferenceSet": string_set_summary(state["point_refs"]),
            }
        )

    require(
        all(len(value) == 1 for value in matches.values()),
        "boss_behavior_graph_not_unique",
    )
    graphs = [matches[key][0] for key in keys]
    require(
        all(graph["nodeCount"] > 0 for graph in graphs),
        "boss_behavior_graph_invalid",
    )
    receipt = {
        "schemaVersion": 1,
        "contractId": "nll/boss-behavior-assembly/v1",
        "profileCode": source["profileCode"],
        "seasonNumber": source["seasonNumber"],
        "sourceDiscoverySha256": sha256_file(source_path),
        "modeCode": "preserve_exact_external_behavior_tree",
        "rootReferenceCount": len(keys),
        "rootReferenceSetSha256": behavior["rootReferenceSetSha256"],
        "assetClosureStatusCode": "resolved",
        "bundleByteLength": bundle_path.stat().st_size,
        "bundleSha256": sha256_file(bundle_path),
        "externalBehaviorTreeCount": external_count,
        "graphMatchCount": len(graphs),
        "nodeCount": sum(graph["nodeCount"] for graph in graphs),
        "disabledNodeCount": sum(graph["disabledNodeCount"] for graph in graphs),
        "canonicalGraphSha256": aggregate_hash(
            [graph["canonicalGraphSha256"] for graph in graphs]
        ),
        "taskTypeSetSha256": aggregate_hash(
            [graph["taskTypeSet"]["canonicalSha256"] for graph in graphs]
        ),
        "skillAnimationReferenceSetSha256": aggregate_hash(
            [
                graph["skillAnimationReferenceSet"]["canonicalSha256"]
                for graph in graphs
            ]
        ),
        "partReferenceSetSha256": aggregate_hash(
            [graph["partReferenceSet"]["canonicalSha256"] for graph in graphs]
        ),
        "pointReferenceSetSha256": aggregate_hash(
            [graph["pointReferenceSet"]["canonicalSha256"] for graph in graphs]
        ),
        "rawSourceIdentifiersPersisted": False,
        "sourceAssetModified": False,
    }
    if getattr(args, "count_quick_time_event_nodes", False):
        # Solo onboarding decides QTE use from this count. Other callers (Union Hard)
        # keep their published receipt bytes unchanged.
        receipt["quickTimeEventNodeCount"] = sum(graph["quickTimeEventNodeCount"] for graph in graphs)
    write_atomic(output_path, receipt)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--private-discovery", required=True, type=Path)
    result.add_argument("--source-discovery", required=True, type=Path)
    result.add_argument("--behavior-bundle", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--unitypy-root", type=Path)
    result.add_argument("--count-quick-time-event-nodes", action="store_true")
    return result


def main() -> int:
    try:
        run(parser().parse_args())
        return 0
    except PipelineError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception:
        print("boss_behavior_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

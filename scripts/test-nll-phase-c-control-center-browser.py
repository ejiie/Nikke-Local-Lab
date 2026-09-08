import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait_status(page, text: str) -> None:
    expect(page.locator("#status")).to_have_text(text, timeout=30_000)


def output_json(page, selector: str) -> dict:
    return json.loads(page.locator(selector).inner_text())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--bootstrap-code", required=True)
    parser.add_argument("--account-uid", required=True)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--draft", required=True, type=Path)
    parser.add_argument("--progression", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--screenshot", required=True, type=Path)
    args = parser.parse_args()

    snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
    source_commander = snapshot["account"]["commanderLevel"]
    local_commander = source_commander + 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.screenshot.parent.mkdir(parents=True, exist_ok=True)

    current_step = "browser_launch"
    browser = None
    context = None
    page = None
    network_events = []
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            context = browser.new_context(viewport={"width": 1440, "height": 1200})
            page = context.new_page()
            page.on(
                "requestfailed",
                lambda request: network_events.append(
                    {
                        "kind": "request_failed",
                        "method": request.method,
                        "path": request.url.split(args.base_url, 1)[-1],
                        "failure": request.failure,
                    }
                ),
            )
            page.on(
                "response",
                lambda response: network_events.append(
                    {
                        "kind": "http_error",
                        "status": response.status,
                        "path": response.url.split(args.base_url, 1)[-1],
                    }
                )
                if response.status >= 400
                else None,
            )
            current_step = "editor_load"
            page.goto(f"{args.base_url}/editor/", wait_until="networkidle")

            current_step = "admin_login"
            page.locator("#bootstrap-code").fill(args.bootstrap_code)
            page.locator("#admin-login").click()
            wait_status(page, "Admin session 완료")

            current_step = "account_load"
            page.locator("#account-uid").fill(args.account_uid)
            page.locator("#load-account").click()
            wait_status(page, "Account load 완료")
            current_step = "local_state_load"
            page.locator("#load-local-state").click()
            wait_status(page, "Local state load 완료")

            initial_display_name = page.locator("#display-name").input_value()
            initial_commander = int(page.locator("#commander-level").input_value())
            if initial_commander != source_commander:
                raise RuntimeError("control_center_initial_commander_mismatch")

            current_step = "local_commander_save"
            page.locator("#commander-level").fill(str(local_commander))
            page.locator("#save-lobby").click()
            wait_status(page, "Lobby save 완료")

            current_step = "snapshot_register"
            page.locator("#fetched-snapshot-file").set_input_files(str(args.snapshot))
            page.locator("#fetched-draft-file").set_input_files(str(args.draft))
            page.locator("#fetched-progression-file").set_input_files(str(args.progression))
            page.locator("#register-fetched-snapshot").click()
            wait_status(page, "Fetched snapshot register 완료")

            current_step = "lobby_diff_preview"
            page.locator("#preview-fetched-lobby").click()
            wait_status(page, "Fetched lobby diff 완료")
            preview = output_json(page, "#local-state-output")["fetchedLobbyDiff"]
            changes = preview["changes"]
            if len(changes) != 1:
                raise RuntimeError("control_center_commander_diff_count_invalid")
            change = changes[0]
            if (
                change["fieldCode"] != "commander_level"
                or change["beforeInteger"] != local_commander
                or change["afterInteger"] != source_commander
            ):
                raise RuntimeError("control_center_commander_diff_invalid")

            current_step = "lobby_selective_apply"
            page.locator("#apply-fetched-lobby").click()
            wait_status(page, "Fetched lobby apply 완료")
            applied = output_json(page, "#local-state-output")
            lobby = applied["lobby"]
            if lobby["commanderLevel"] != source_commander:
                raise RuntimeError("control_center_commander_apply_invalid")
            if lobby["displayName"] != initial_display_name:
                raise RuntimeError("control_center_unselected_lobby_field_changed")
            if int(page.locator("#commander-level").input_value()) != source_commander:
                raise RuntimeError("control_center_commander_input_not_refreshed")

            current_step = "success_screenshot"
            page.screenshot(path=str(args.screenshot), full_page=True)
            context.close()
            browser.close()
    except Exception as error:
        status = None
        if page is not None:
            try:
                status = page.locator("#status").inner_text(timeout=2_000)
                page.screenshot(path=str(args.screenshot), full_page=True)
            except Exception:
                pass
        failure = {
            "schemaVersion": 1,
            "contractId": "nll/phase-c-control-center-browser-failure/v1",
            "failedAtUtc": datetime.now(timezone.utc).isoformat(),
            "stepCode": current_step,
            "statusText": status,
            "errorType": type(error).__name__,
            "errorMessage": str(error),
            "networkEvents": network_events,
        }
        failure_path = args.receipt.with_name("control-center-browser.failure.json")
        failure_path.write_text(
            json.dumps(failure, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps(failure, ensure_ascii=False, indent=2))
        raise

    receipt = {
        "schemaVersion": 1,
        "contractId": "nll/phase-c-control-center-browser-acceptance/v1",
        "completedAtUtc": datetime.now(timezone.utc).isoformat(),
        "accountUid": args.account_uid,
        "snapshotUid": snapshot["snapshotUid"],
        "registeredThroughControlCenter": True,
        "sourceCommanderLevel": source_commander,
        "localCommanderLevelBeforeDiff": local_commander,
        "commanderDiffCount": 1,
        "commanderDiffSha256": preview["diffSha256"],
        "commanderSelectedApplyVerified": True,
        "unselectedLobbyFieldsPreserved": True,
        "browserEngine": "playwright_chromium",
        "browserHeadless": True,
        "screenshotByteLength": args.screenshot.stat().st_size,
        "screenshotSha256": sha256(args.screenshot),
        "rawSourcePersisted": False,
        "officialUserIdentifierPersisted": False,
        "credentialOrSessionPersisted": False,
        "officialOutboundUsed": False,
        "goldenModified": False,
        "gameRuntimeModified": False,
        "verdictCode": "control_center_register_diff_selective_apply_passed",
        "nextStepCode": "close_phase_c_after_regression_verification",
    }
    args.receipt.write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(receipt, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

// The toolbar popup: pair with a code from Clew's Settings, then show the last import.

import type { StatusAnswer, Status } from "./background";

const t = (key: string, ...subs: string[]) => chrome.i18n.getMessage(key, subs) || key;
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function describe(status: Status | undefined): string {
  if (!status) return t("statusWaiting");
  if (!status.ok) {
    if (status.problem === "unreachable") return t("statusOpenClew");
    if (status.problem === "revoked") return t("statusRevoked");
    if (status.problem === "turnedOff") return t("statusTurnedOff");
    return t("statusFailed");
  }
  const x = status.source === "extension.x";
  if (status.needsUpdate) return t(x ? "statusNeedsUpdateX" : "statusNeedsUpdate");
  return t(x ? "statusImportedX" : "statusImported", String(status.added ?? 0), String(status.listCount ?? 0));
}

async function render(): Promise<void> {
  const answer = (await chrome.runtime.sendMessage({ type: "status" })) as StatusAnswer;
  $("unpaired").hidden = answer.paired;
  $("paired").hidden = !answer.paired;
  $("statusLine").textContent = describe(answer.status);
}

$("pairHint").textContent = t("pairHint");
$("codeLabel").textContent = t("codeLabel");
$<HTMLInputElement>("code").setAttribute("aria-label", t("codeLabel"));
$("pairButton").textContent = t("pairButton");
$("openWatchLater").textContent = t("openWatchLater");
$("forget").textContent = t("forget");

$<HTMLFormElement>("pairForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = $<HTMLInputElement>("code").value.replace(/\D/g, "");
  if (code.length !== 6) {
    $("pairError").textContent = t("pairErrorCode");
    return;
  }
  $("pairError").textContent = "";
  const result = (await chrome.runtime.sendMessage({ type: "pair", code })) as { ok: boolean; problem?: string };
  if (result.ok) return render();
  $("pairError").textContent = result.problem === "code" ? t("pairErrorCode") : t("statusOpenClew");
});

$("openWatchLater").addEventListener("click", () => {
  chrome.tabs.create({ url: "https://www.youtube.com/playlist?list=WL" });
});

$("forget").addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "forget" });
  await render();
});

render();

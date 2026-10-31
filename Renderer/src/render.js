// Markdown renderer for the artifact viewer.
// micromark escapes raw HTML by default (allowDangerousHtml: false), so the
// rendered document cannot inject scripts; the page CSP blocks the rest.
import { micromark } from "micromark";
import { gfm, gfmHtml } from "micromark-extension-gfm";

function render(source) {
  return micromark(source, {
    extensions: [gfm()],
    htmlExtensions: [gfmHtml()],
  });
}

function currentScrollRatio() {
  const max = document.documentElement.scrollHeight - window.innerHeight;
  return max > 0 ? window.scrollY / max : 0;
}

function restoreScroll(ratio) {
  const max = document.documentElement.scrollHeight - window.innerHeight;
  window.scrollTo(0, Math.round(max * ratio));
}

function showRaw(container, source, reason) {
  const notice = document.createElement("p");
  notice.className = "render-error";
  notice.textContent = `렌더링 실패 — 원문 표시 (${reason})`;
  const pre = document.createElement("pre");
  pre.textContent = source;
  container.replaceChildren(notice, pre);
}

// Called from Swift: { source: string, keepScroll: boolean }
window.aibccShow = (payload) => {
  const container = document.getElementById("doc");
  const ratio = payload.keepScroll ? currentScrollRatio() : 0;
  try {
    container.innerHTML = render(payload.source);
  } catch (error) {
    showRaw(container, payload.source, String(error));
  }
  window.requestAnimationFrame(() => restoreScroll(ratio));
  return true;
};

// ==UserScript==
// @name         Autotask - Click-to-Dial (tel:) for plain numbers
// @namespace    https://example.local/
// @version      1.0
// @description  Turns plain-text phone numbers into tel: links (works with Elevate handler)
// @match        https://*.autotask.net/*
// @run-at       document-idle
// ==/UserScript==

(function () {
  "use strict";

  // Loose US phone matcher: (870) 830-4352, 870-830-4352, 870.830.4352, 8708304352, ext 123
  const phoneRegex =
    /(?:\+?1[\s.-]?)?(?:\(\s*\d{3}\s*\)|\d{3})[\s.-]?\d{3}[\s.-]?\d{4}(?:\s*(?:x|ext\.?|extension)\s*\d{1,6})?/gi;
  const extRegex = /\s*(?:x|ext\.?|extension)\s*(\d{1,6})/i;
  let cachedLinkClass = "";
  let cachedLinkStyle = "";
  let hasReferenceLink = false;

  function normalizeToTel(s) {
    const extMatch = s.match(extRegex);
    const ext = extMatch ? extMatch[1] : "";
    const core = extMatch ? s.replace(extRegex, "") : s;

    const digits = core.replace(/[^\d+]/g, "");
    const justDigits = digits.replace(/\D/g, "");
    if (justDigits.length < 10 || justDigits.length > 15) {
      return null;
    }

    let normalized = "";
    if (justDigits.length === 10) {
      normalized = `+1${justDigits}`;
    } else if (justDigits.length === 11 && justDigits.startsWith("1")) {
      normalized = `+${justDigits}`;
    } else {
      normalized = digits.startsWith("+") ? `+${justDigits}` : `+${justDigits}`;
    }

    return ext ? `${normalized};ext=${ext}` : normalized;
  }

  function updateReferenceLinkInfo() {
    if (hasReferenceLink) {
      return true;
    }
    const anchors = document.querySelectorAll("a");
    for (const a of anchors) {
      if (a.textContent && a.textContent.trim() === "Site Configuration") {
        cachedLinkClass = a.className || "";
        cachedLinkStyle = a.getAttribute("style") || "";
        hasReferenceLink = true;
        return true;
      }
    }
    return false;
  }

  function applyReferenceLinkAppearance(a) {
    if (!updateReferenceLinkInfo()) {
      return;
    }
    if (cachedLinkClass) {
      a.className = cachedLinkClass;
    }
    if (cachedLinkStyle) {
      a.setAttribute("style", cachedLinkStyle);
    }
  }

  function shouldSkipNode(node) {
    if (!node || !node.parentElement) {
      return true;
    }
    const p = node.parentElement;
    return (
      p.closest(
        "a, button, input, textarea, select, code, pre, kbd, samp, script, style, noscript, [contenteditable]"
      ) !== null
    );
  }

  function linkifyTextNode(textNode) {
    if (shouldSkipNode(textNode)) {
      return;
    }
    const text = textNode.nodeValue;
    if (!text || !phoneRegex.test(text)) {
      return;
    }

    // reset regex state after test()
    phoneRegex.lastIndex = 0;

    const frag = document.createDocumentFragment();
    let lastIndex = 0;
    let match;

    while ((match = phoneRegex.exec(text)) !== null) {
      const start = match.index;
      const end = start + match[0].length;
      const before = text[start - 1];
      const after = text[end];

      // text before match
      if (start > lastIndex) {
        frag.appendChild(document.createTextNode(text.slice(lastIndex, start)));
      }

      const raw = match[0];
      const tel = normalizeToTel(raw);

      if (
        !tel ||
        (before && /\d/.test(before)) ||
        (after && /\d/.test(after))
      ) {
        frag.appendChild(document.createTextNode(raw));
      } else {
        const a = document.createElement("a");
        a.href = `tel:${tel}`;
        a.textContent = raw;
        applyReferenceLinkAppearance(a);
        a.setAttribute("data-telified", "true");
        frag.appendChild(a);
      }

      lastIndex = end;
    }

    // trailing text
    if (lastIndex < text.length) {
      frag.appendChild(document.createTextNode(text.slice(lastIndex)));
    }

    textNode.parentNode.replaceChild(frag, textNode);
  }

  function walkAndLinkify(root) {
    if (!root) {
      return;
    }
    if (root.nodeType === Node.TEXT_NODE) {
      linkifyTextNode(root);
      return;
    }
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    const nodes = [];
    let n;
    while ((n = walker.nextNode())) {
      nodes.push(n);
    }
    nodes.forEach(linkifyTextNode);
  }

  // Initial pass
  walkAndLinkify(document.body);

  // Watch for SPA/dynamic updates
  const obs = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          walkAndLinkify(node);
        }
        if (node.nodeType === Node.TEXT_NODE) {
          linkifyTextNode(node);
        }
      }
    }
  });
  obs.observe(document.body, { childList: true, subtree: true });
})();

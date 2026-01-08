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

  // Loose US phone matcher: (870) 830-4352, 870-830-4352, 870.830.4352, 8708304352
  const phoneRegex = /(?:\+?1[\s.-]?)?(?:\(\s*\d{3}\s*\)|\d{3})[\s.-]?\d{3}[\s.-]?\d{4}/g;

  function normalizeToTel(s) {
    const digits = s.replace(/[^\d+]/g, "");
    // If 10 digits, assume US +1
    const justDigits = digits.replace(/\D/g, "");
    if (justDigits.length === 10) return `+1${justDigits}`;
    if (justDigits.length === 11 && justDigits.startsWith("1")) return `+${justDigits}`;
    // Fallback: keep whatever digits we got
    return digits.startsWith("+") ? digits : `+${justDigits}`;
  }

  function shouldSkipNode(node) {
    if (!node || !node.parentElement) return true;
    const p = node.parentElement;
    return (
      p.closest("a, button, input, textarea, select, code, pre") !== null
    );
  }

  function linkifyTextNode(textNode) {
    if (shouldSkipNode(textNode)) return;
    const text = textNode.nodeValue;
    if (!text || !phoneRegex.test(text)) return;

    // reset regex state after test()
    phoneRegex.lastIndex = 0;

    const frag = document.createDocumentFragment();
    let lastIndex = 0;
    let match;

    while ((match = phoneRegex.exec(text)) !== null) {
      const start = match.index;
      const end = start + match[0].length;

      // text before match
      if (start > lastIndex) {
        frag.appendChild(document.createTextNode(text.slice(lastIndex, start)));
      }

      const raw = match[0];
      const tel = normalizeToTel(raw);

      const a = document.createElement("a");
      a.href = `tel:${tel}`;
      a.textContent = raw;
      a.style.textDecoration = "underline";
      a.style.cursor = "pointer";

      frag.appendChild(a);

      lastIndex = end;
    }

    // trailing text
    if (lastIndex < text.length) {
      frag.appendChild(document.createTextNode(text.slice(lastIndex)));
    }

    textNode.parentNode.replaceChild(frag, textNode);
  }

  function walkAndLinkify(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    const nodes = [];
    let n;
    while ((n = walker.nextNode())) nodes.push(n);
    nodes.forEach(linkifyTextNode);
  }

  // Initial pass
  walkAndLinkify(document.body);

  // Watch for SPA/dynamic updates
  const obs = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType === 1) walkAndLinkify(node);
      }
    }
  });
  obs.observe(document.body, { childList: true, subtree: true });
})();

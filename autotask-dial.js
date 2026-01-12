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
  const ticketRegex = /T\d{8}\.\d{4}/g;
  const extRegex = /\s*(?:x|ext\.?|extension)\s*(\d{1,6})/i;
  const TEL_LINK_COLOR = "#199ed9";
  const TEL_LINK_FONT_SIZE = "12px";
  const TEL_LINK_LINE_HEIGHT = "20px";
  const TEL_LINK_CLASS = "tel-linkified";
  const TEL_LINK_STYLE_ID = "tel-linkified-style";
  let didApplyReferenceToExisting = false;

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

  function ensureTelLinkStyles() {
    if (document.getElementById(TEL_LINK_STYLE_ID)) {
      return;
    }
    const style = document.createElement("style");
    style.id = TEL_LINK_STYLE_ID;
    style.textContent = `
.${TEL_LINK_CLASS} { text-decoration: none !important; }
.${TEL_LINK_CLASS}:hover { text-decoration: underline !important; }
`;
    document.head.appendChild(style);
  }

  function applyReferenceLinkAppearance(a) {
    ensureTelLinkStyles();
    a.classList.add(TEL_LINK_CLASS);
    a.style.setProperty("color", TEL_LINK_COLOR, "important");
    a.style.setProperty("font-size", TEL_LINK_FONT_SIZE, "important");
    a.style.setProperty("line-height", TEL_LINK_LINE_HEIGHT, "important");
  }

  function applyReferenceStylesToExistingLinks() {
    if (didApplyReferenceToExisting) {
      return;
    }
    const telLinks = document.querySelectorAll("a[data-telified='true']");
    if (!telLinks.length) {
      return;
    }
    telLinks.forEach((a) => applyReferenceLinkAppearance(a));
    didApplyReferenceToExisting = true;
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
      const insideTicket = isWithinTicketNumber(text, start, end);

      // text before match
      if (start > lastIndex) {
        frag.appendChild(document.createTextNode(text.slice(lastIndex, start)));
      }

      const raw = match[0];
      const tel = normalizeToTel(raw);

      if (
        insideTicket ||
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

  function isWithinTicketNumber(text, start, end) {
    ticketRegex.lastIndex = 0;
    let match;
    while ((match = ticketRegex.exec(text)) !== null) {
      const ticketStart = match.index;
      const ticketEnd = ticketStart + match[0].length;
      if (start < ticketEnd && end > ticketStart) {
        return true;
      }
    }
    return false;
  }

  // Initial pass
  walkAndLinkify(document.body);
  applyReferenceStylesToExistingLinks();

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
    applyReferenceStylesToExistingLinks();
  });
  obs.observe(document.body, { childList: true, subtree: true });
})();

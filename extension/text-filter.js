// Lightweight port of GlobalTranslatorCore.TextFilter skip rules.
// Used by the content script before a loopback POST, and by Node tests.
(function (root) {
  const TECHNICAL_ABBREVIATIONS = {
    AI: true, API: true, CPU: true, GPU: true, USB: true, HTTP: true,
    HTTPS: true, JSON: true, HTML: true, CSS: true, PDF: true, PNG: true,
    JPG: true, JPEG: true, URL: true, IP: true, DNS: true, RAM: true,
    SSD: true, SDK: true, CLI: true, SQL: true, UTF: true
  };
  const MODIFIER_WORDS = {
    cmd: true, command: true, ctrl: true, control: true, alt: true,
    option: true, opt: true, shift: true, fn: true, win: true, windows: true
  };
  const GLUE_WORDS = {
    and: true, or: true, with: true, for: true, to: true, of: true,
    in: true, on: true, vs: true, versus: true, plus: true
  };
  const IDENTIFIER_PATTERNS = [
    /^\.[A-Za-z][A-Za-z0-9_.-]*$/,
    /^[A-Za-z_][A-Za-z0-9_]*_[A-Za-z0-9_]+$/,
    /^[a-z]+(?:[A-Z][A-Za-z0-9]*)+$/,
    /^[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+$/,
    /^\.?[A-Za-z0-9_.-]+\.(?:swift|tsx?|jsx?|json|ya?ml|toml|md|plist|lock|sh|css|html)(?:\s+[AMUDR?]|\s+\d+)?$/i,
    /^0x[0-9a-f]+$/i,
    /^v?\d+(?:\.\d+){2,}(?:[-+][a-z0-9.-]+)?$/i,
    /^\d+(?:\.\d+)?\s*(?:[kmgt]i?b|bytes?|fps|hz|khz|mhz|ghz|px|dpi|ms|s|sec|min|%)$/i,
    /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i,
    /^[A-Za-z_][A-Za-z0-9_.]*\(\)$/
  ];

  function hasLetter(value) {
    return /[A-Za-z\u00C0-\u024F]/.test(value) || /[\u3400-\u9FFF\u3040-\u30FF\u1100-\u11FF\uAC00-\uD7AF]/.test(value);
  }

  function isURL(value) {
    if (/\s/.test(value)) return false;
    const lower = value.toLowerCase();
    if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0 ||
        lower.indexOf("ftp://") === 0 || lower.indexOf("www.") === 0) {
      return true;
    }
    return /^(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#].*)?$/i.test(value);
  }

  function isEmail(value) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  }

  function isFilePath(value) {
    const prefixPath = value.indexOf("/") === 0 || value.indexOf("~/") === 0 ||
      value.indexOf("./") === 0 || value.indexOf("../") === 0 ||
      value.indexOf(".\\") === 0 || value.indexOf("..\\") === 0;
    const windowsPath = /^[A-Za-z]:[\\/]/.test(value);
    const nestedPath = !/\s/.test(value) && (value.indexOf("/") !== -1 || value.indexOf("\\") !== -1) &&
      /[/\\][^/\\]+(?:[/\\]|\.[a-z0-9]+$)/i.test(value);
    return prefixPath || windowsPath || nestedPath;
  }

  function isShortcutOnly(value) {
    const compact = value.replace(/ /g, "").toLowerCase();
    if (MODIFIER_WORDS[compact]) return true;
    const symbols = /[⌘⌃⌥⇧⇪]/g;
    const symbolCount = (compact.match(symbols) || []).length;
    const nonSymbols = compact.replace(/[⌘⌃⌥⇧⇪+\-]/g, "");
    if (symbolCount > 0 && nonSymbols.length <= 1) return true;
    const pieces = compact.split(/[+\-]/).filter(Boolean);
    if (pieces.length < 2 || pieces.length > 5) return false;
    for (let i = 0; i < pieces.length - 1; i++) {
      if (!MODIFIER_WORDS[pieces[i]]) return false;
    }
    return /^(?:[a-z0-9]|f[0-9]{1,2}|tab|enter|return|space|escape|esc|delete|backspace)$/i.test(pieces[pieces.length - 1]);
  }

  function isIdentifierOrUnit(value) {
    if (value.length === 1 && /^[\x00-\x7F]$/.test(value)) return true;
    for (let i = 0; i < IDENTIFIER_PATTERNS.length; i++) {
      if (IDENTIFIER_PATTERNS[i].test(value)) return true;
    }
    return false;
  }

  function isVersionToken(token) {
    return /^v?\d+(?:\.\d+)*[A-Za-z]?$/.test(token);
  }

  function hasInternalCamelCase(token) {
    const letters = token.replace(/[^A-Za-z]/g, "");
    if (letters.length < 2) return false;
    const upperCount = (letters.match(/[A-Z]/g) || []).length;
    return /[a-z]/.test(letters) && upperCount >= 2;
  }

  function isAllCapsAbbreviation(token) {
    const letters = token.replace(/[^A-Za-z]/g, "");
    if (letters.length < 2 || letters.length > 8) return false;
    if (letters !== letters.toUpperCase()) return false;
    return /^[A-Za-z0-9]+$/.test(token);
  }

  function isCapitalizedProductWord(token) {
    return /^[A-Z][a-zA-Z0-9]*$/.test(token);
  }

  function isTechnicalToken(token) {
    return isVersionToken(token) ||
      hasInternalCamelCase(token) ||
      isIdentifierOrUnit(token) ||
      isAllCapsAbbreviation(token) ||
      TECHNICAL_ABBREVIATIONS[token.toUpperCase()] ||
      isCapitalizedProductWord(token);
  }

  function isTechnicalTokenPhrase(value) {
    if (/[?!。？]/.test(value)) return false;
    if (/[\u3400-\u9FFF\u3040-\u30FF\u1100-\u11FF\uAC00-\uD7AF]/.test(value)) return false;
    const tokens = value.split(/[\s+/|&,]+/).filter(Boolean);
    if (tokens.length < 2 || tokens.length > 8) return false;
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (!isTechnicalToken(token) && !GLUE_WORDS[token.toLowerCase()]) return false;
    }
    if (tokens.some(hasInternalCamelCase)) return true;
    const hasAllCaps = tokens.some(isAllCapsAbbreviation);
    const hasPeerName = tokens.some((token) => (
      !isVersionToken(token) &&
      !isAllCapsAbbreviation(token) &&
      (hasInternalCamelCase(token) || isCapitalizedProductWord(token) || isIdentifierOrUnit(token))
    ));
    return hasAllCaps && hasPeerName;
  }

  function shouldTranslate(text) {
    const value = String(text || "").trim();
    if (!value) return false;
    if (isURL(value) || isEmail(value) || isFilePath(value) || isShortcutOnly(value) || isIdentifierOrUnit(value)) {
      return false;
    }
    if (!hasLetter(value)) return false;
    if (isTechnicalTokenPhrase(value)) return false;
    return true;
  }

  // Page-bridge gate: never POST fragments that Core would skip, plus
  // already-Chinese / no-Latin nodes the content script used to drop.
  function shouldSendForPageTranslate(text) {
    const value = String(text || "").trim();
    if (value.length < 2) return false;
    if (!/[A-Za-z]/.test(value) || /[一-鿿]/.test(value)) return false;
    return shouldTranslate(value);
  }

  const api = {
    shouldTranslate,
    shouldSendForPageTranslate
  };
  root.GlobalTranslatorTextFilter = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);

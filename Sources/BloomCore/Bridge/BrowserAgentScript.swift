import Foundation

/// The scripts behind `browser_snapshot`, `browser_click`, `browser_fill`, `browser_press`,
/// `browser_wait` and `browser_network`.
///
/// **Every one is a function body for `callAsyncJavaScript`, and a caller's text only ever arrives
/// as one of its arguments.** WebKit hands those over as JavaScript values, so a reference, a key
/// or a line typed into a field reaches the page as a string it may use and never as source it
/// runs. That is the same promise `BrowserPageScript` keeps by having no case that carries a
/// string, kept here by construction instead: nothing in this file is interpolated from outside
/// it, and `BrowserInteractionTests` holds that.
///
/// **They run in a content world of Bloom's own, not the page's.** A content world shares the DOM
/// and nothing else, so the elements are the real ones while `document.querySelectorAll`,
/// `HTMLInputElement.prototype` and the map of references are Bloom's. A page cannot replace the
/// function a click goes through, read which elements were handed out, or point `e3` at a
/// different button between the snapshot and the click.
///
/// The console is the one thing that cannot be read from here, and `BrowserConsoleScript` says
/// why.
public enum BrowserAgentScript {
    /// The name of Bloom's content world. One per web view, and WebKit clears its globals when a
    /// document is replaced, which is exactly when every reference ought to stop meaning anything.
    public static let worldName = "bloom-agent"

    /// Shared by every script below: where the references live, and how an element is named in
    /// an answer. A function declaration rather than a global, so each call is self-contained.
    private static let prelude = """
        const bloom = globalThis.__bloomAgent || (globalThis.__bloomAgent = { refs: new Map(), next: 1 });
        const clip = (value, limit) => String(value == null ? "" : value).replace(/\\s+/g, " ").trim().slice(0, limit);
        const visible = (element) => {
          if (!element.isConnected) { return false; }
          if (typeof element.checkVisibility === "function"
              && !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) { return false; }
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        """

    /// An outline of what can be read and acted on, with a reference for each element.
    ///
    /// Arguments: `limit`, the most elements to describe; `chars`, the longest a name may be.
    /// Answers `{ rows, total }`, where `rows` is six strings per element: reference, role, name,
    /// value, detail and flags. What those mean is `BrowserPageOutline`.
    ///
    /// A password field reports how long its value is and never the value, because a snapshot is
    /// carried into a model's context and a page the owner is signed into can be holding his.
    public static let snapshot = prelude + """
        bloom.refs = new Map();
        bloom.next = 1;
        const interactiveRoles = new Set(["button", "link", "checkbox", "radio", "switch", "tab",
          "menuitem", "menuitemcheckbox", "menuitemradio", "option", "combobox", "textbox",
          "searchbox", "slider", "spinbutton", "treeitem"]);
        const textTypes = new Set(["", "text", "email", "password", "search", "tel", "url", "number",
          "date", "datetime-local", "month", "time", "week", "color"]);

        const labelOf = (element) => {
          const aria = element.getAttribute("aria-label");
          if (aria) { return aria; }
          const labelledBy = element.getAttribute("aria-labelledby");
          if (labelledBy) {
            const text = labelledBy.split(/\\s+/).map((id) => {
              const found = document.getElementById(id);
              return found ? found.innerText : "";
            }).join(" ");
            if (text.trim()) { return text; }
          }
          if (element.labels && element.labels.length) { return element.labels[0].innerText; }
          return "";
        };

        const describe = (element) => {
          const tag = element.tagName.toLowerCase();
          const role = (element.getAttribute("role") || "").toLowerCase();
          const type = (element.getAttribute("type") || "").toLowerCase();
          let kind = "";
          let value = "";
          let detail = "";
          if (/^h[1-6]$/.test(tag)) { kind = "heading"; detail = "level=" + tag.slice(1); }
          else if (tag === "a" && element.hasAttribute("href")) { kind = "link"; detail = clip(element.getAttribute("href"), chars); }
          else if (tag === "button" || tag === "summary") { kind = "button"; }
          else if (tag === "input") {
            if (type === "hidden") { return null; }
            if (type === "checkbox" || type === "radio") { kind = type; }
            else if (type === "button" || type === "submit" || type === "reset" || type === "image") { kind = "button"; }
            else if (type === "range") { kind = "slider"; value = element.value; }
            else if (type === "file") { kind = "file"; }
            else if (textTypes.has(type)) {
              kind = "textbox";
              detail = type ? "type=" + type : "";
              value = type === "password" ? (element.value ? "(" + element.value.length + " characters hidden)" : "") : element.value;
            }
          }
          else if (tag === "textarea") { kind = "textbox"; detail = "multiline"; value = element.value; }
          else if (tag === "select") {
            kind = "combobox";
            const chosen = element.selectedOptions && element.selectedOptions[0];
            value = chosen ? chosen.text : "";
            detail = "options=" + Array.from(element.options).slice(0, 25).map((option) => clip(option.text, 40)).join(" | ");
          }
          else if (element.isContentEditable && !(element.parentElement && element.parentElement.isContentEditable)) {
            kind = "textbox"; detail = "rich"; value = element.innerText;
          }
          else if (interactiveRoles.has(role)) { kind = role; }
          else if (tag === "img" && element.getAttribute("alt")) { kind = "image"; }
          else if (element.hasAttribute("onclick") || (element.tabIndex >= 0 && element.hasAttribute("tabindex"))) { kind = "clickable"; }
          if (!kind) { return null; }
          if (role && interactiveRoles.has(role)) { kind = role; }

          let name = labelOf(element);
          if (!name && kind !== "textbox" && kind !== "combobox") { name = element.innerText || ""; }
          if (!name) { name = element.getAttribute("placeholder") || element.getAttribute("title") || element.getAttribute("alt") || ""; }
          if (!name && (tag === "input") && (kind === "button")) { name = element.value; }
          if (!name) {
            const image = element.querySelector && element.querySelector("img[alt], svg title");
            if (image) { name = image.getAttribute("alt") || image.textContent || ""; }
          }

          const flags = [];
          if (element.disabled || element.getAttribute("aria-disabled") === "true") { flags.push("disabled"); }
          if (element.checked || element.getAttribute("aria-checked") === "true") { flags.push("checked"); }
          if (element.getAttribute("aria-expanded") === "true") { flags.push("expanded"); }
          if (element.getAttribute("aria-selected") === "true") { flags.push("selected"); }
          if (element.required) { flags.push("required"); }
          if (element.readOnly) { flags.push("readonly"); }
          if (document.activeElement === element) { flags.push("focused"); }
          const rect = element.getBoundingClientRect();
          if (rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth) {
            flags.push("offscreen");
          }
          return [kind, clip(name, chars), clip(value, chars), detail, flags.join(",")];
        };

        const rows = [];
        let total = 0;
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
        for (let node = walker.currentNode; node; node = walker.nextNode()) {
          const described = describe(node);
          if (!described || !visible(node)) { continue; }
          total += 1;
          if (rows.length >= limit * 6) { continue; }
          const ref = bloom.next;
          bloom.next += 1;
          bloom.refs.set(ref, node);
          rows.push(String(ref), ...described);
        }
        return { rows: rows, total: total };
        """

    /// Answers the element a reference names, or a word saying why there is none.
    private static let lookup = """
        const element = bloom.refs.get(ref);
        if (!element) { return ["missing"]; }
        if (!element.isConnected) { return ["detached"]; }
        """

    /// A click, as the events a mouse would produce, ending in the element's own `click()` so a
    /// link follows, a checkbox toggles and a submit button submits.
    ///
    /// Arguments: `ref`. Answers `["clicked", covering]`, where `covering` names an element lying
    /// over the middle of the target when there is one: a click a modal would have intercepted
    /// for a person is a fact the model needs, even though these events go to the target itself.
    public static let click = prelude + lookup + """
        if (element.disabled) { return ["disabled"]; }
        element.scrollIntoView({ block: "center", inline: "center" });
        const rect = element.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const top = document.elementFromPoint(x, y);
        let covering = "";
        if (top && top !== element && !element.contains(top) && !top.contains(element)) {
          covering = top.tagName.toLowerCase() + (top.id ? "#" + top.id : "") + " " + clip(top.innerText, 60);
        }
        const options = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0 };
        element.dispatchEvent(new PointerEvent("pointerdown", { ...options, pointerType: "mouse", isPrimary: true }));
        element.dispatchEvent(new MouseEvent("mousedown", options));
        if (typeof element.focus === "function") { element.focus({ preventScroll: true }); }
        element.dispatchEvent(new PointerEvent("pointerup", { ...options, pointerType: "mouse", isPrimary: true }));
        element.dispatchEvent(new MouseEvent("mouseup", options));
        element.click();
        return ["clicked", covering];
        """

    /// Replaces what is in a field, or chooses an option.
    ///
    /// Arguments: `ref`, `text`. Answers `["filled"]`, `["selected", option]`, or a word saying
    /// why not.
    ///
    /// **The value is set through the prototype's setter, not through `element.value`.** React
    /// and friends install their own `value` property on the element to notice changes, and a
    /// write through it updates their record along with the field, so the `input` event that
    /// follows finds nothing different and the form's state never hears about it. The setter from
    /// `HTMLInputElement.prototype` in this world skips that record, which is the difference that
    /// makes a controlled input take the text.
    public static let fill = prelude + lookup + """
        if (element.disabled) { return ["disabled"]; }
        element.scrollIntoView({ block: "center" });
        if (typeof element.focus === "function") { element.focus({ preventScroll: true }); }
        if (element instanceof HTMLSelectElement) {
          const options = Array.from(element.options);
          const wanted = text.trim();
          const option = options.find((candidate) => candidate.value === text)
            || options.find((candidate) => candidate.text.trim() === wanted)
            || options.find((candidate) => candidate.text.trim().toLowerCase() === wanted.toLowerCase());
          if (!option) { return ["no-option", options.slice(0, 25).map((candidate) => clip(candidate.text, 40)).join(" | ")]; }
          element.value = option.value;
          element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
          return ["selected", clip(option.text, 80)];
        }
        if (element.isContentEditable) {
          element.textContent = text;
          element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
          return ["filled"];
        }
        const isInput = element instanceof HTMLInputElement;
        if (!isInput && !(element instanceof HTMLTextAreaElement)) { return ["not-editable", element.tagName.toLowerCase()]; }
        if (isInput && ["checkbox", "radio", "button", "submit", "reset", "file", "image", "hidden"].includes(element.type)) {
          return ["not-editable", "input type=" + element.type];
        }
        if (element.readOnly) { return ["readonly"]; }
        const prototype = isInput ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, text);
        element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
        element.dispatchEvent(new Event("change", { bubbles: true }));
        return ["filled"];
        """

    /// One key press on the focused element, or on a referenced one after focusing it.
    ///
    /// Arguments: `ref` (zero for "whatever has focus"), `key`, `code`, `keyCode`, `shift`,
    /// `control`, `alt`, `meta`, `character`. Answers `[outcome, focused]`.
    ///
    /// **Events a script dispatches are not trusted, and a browser does nothing by default for
    /// them.** A real Enter in a form submits it, a real Tab moves focus and a real letter types;
    /// a synthetic `keydown` does none of those. So the three defaults a model most expects are
    /// done here by hand, and only when the page did not cancel the event: Enter submits the
    /// enclosing form or activates a button or link, Tab moves focus, and a character or Backspace
    /// edits a text field.
    public static let press = prelude + """
        let target = document.activeElement || document.body;
        if (ref > 0) {
          const element = bloom.refs.get(ref);
          if (!element) { return ["missing", ""]; }
          if (!element.isConnected) { return ["detached", ""]; }
          if (typeof element.focus === "function") { element.focus({ preventScroll: false }); }
          target = element;
        }
        const init = { key: key, code: code, keyCode: keyCode, which: keyCode, bubbles: true,
          cancelable: true, composed: true, shiftKey: shift, ctrlKey: control, altKey: alt, metaKey: meta };
        const proceed = target.dispatchEvent(new KeyboardEvent("keydown", init));
        let outcome = proceed ? "pressed" : "cancelled";
        const editable = (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) && !target.readOnly && !target.disabled;
        if (proceed && character && !control && !meta) {
          target.dispatchEvent(new KeyboardEvent("keypress", { ...init, charCode: key.charCodeAt(0) }));
          if (editable) {
            const start = target.selectionStart ?? target.value.length;
            const end = target.selectionEnd ?? target.value.length;
            try { target.setRangeText(key, start, end, "end"); } catch (error) { target.value = target.value + key; }
            target.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: key }));
          }
        } else if (proceed && key === "Backspace" && editable) {
          const start = target.selectionStart ?? target.value.length;
          const end = target.selectionEnd ?? target.value.length;
          const from = start === end ? Math.max(0, start - 1) : start;
          try { target.setRangeText("", from, end, "end"); } catch (error) { target.value = target.value.slice(0, -1); }
          target.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "deleteContentBackward" }));
        } else if (proceed && key === "Enter" && !shift) {
          if (target instanceof HTMLInputElement && target.form) {
            if (typeof target.form.requestSubmit === "function") { target.form.requestSubmit(); } else { target.form.submit(); }
            outcome = "submitted";
          } else if (target instanceof HTMLButtonElement || target instanceof HTMLAnchorElement) {
            target.click();
            outcome = "activated";
          }
        } else if (proceed && key === "Tab") {
          const focusable = Array.from(document.querySelectorAll(
            "a[href], button, input:not([type=hidden]), select, textarea, [tabindex], [contenteditable=true]"
          )).filter((element) => element.tabIndex >= 0 && !element.disabled && visible(element));
          const index = focusable.indexOf(target);
          const next = focusable[(index + (shift ? -1 : 1) + focusable.length) % focusable.length];
          if (next) { next.focus(); outcome = "moved"; }
        }
        target.dispatchEvent(new KeyboardEvent("keyup", init));
        const now = document.activeElement;
        const focused = now && now !== document.body
          ? now.tagName.toLowerCase() + " " + clip(now.getAttribute("aria-label") || (now.labels && now.labels.length ? now.labels[0].innerText : "") || now.innerText || now.getAttribute("placeholder") || now.getAttribute("name") || "", 60)
          : "";
        return [outcome, focused];
        """

    /// Whether what `browser_wait` is waiting for is there. Not async and not a loop: the loop is
    /// in Swift, because a navigation in the middle of a wait tears down the world the script was
    /// running in and an async script would never answer.
    ///
    /// Arguments: `kind` (`selector` or `text`), `value`. Answers `"yes"`, `"no"` or
    /// `"bad-selector"`.
    public static let check = prelude + """
        if (kind === "selector") {
          let found = null;
          try { found = document.querySelectorAll(value); } catch (error) { return "bad-selector"; }
          return Array.from(found).some(visible) ? "yes" : "no";
        }
        const body = document.body;
        return body && body.innerText.includes(value) ? "yes" : "no";
        """

    /// What the page has fetched since it loaded, out of the browser's own Resource Timing buffer.
    ///
    /// Arguments: `limit`, `chars`. Answers `{ rows, total }`, where `rows` is five strings per
    /// request: type, address, status, milliseconds and bytes.
    ///
    /// **Read rather than recorded**, so it needs nothing installed in the page and covers the
    /// page from the moment it started, including the requests made before anybody asked. What it
    /// cannot say is the method, the headers or a body, and a status only where WebKit reports
    /// `responseStatus`. `BrowserNetworkTool` says so rather than implying a network panel.
    public static let network = """
        const clip = (value, limit) => String(value == null ? "" : value).slice(0, limit);
        const entries = performance.getEntriesByType("navigation").concat(performance.getEntriesByType("resource"));
        const rows = [];
        const start = Math.max(0, entries.length - limit);
        for (let index = start; index < entries.length; index += 1) {
          const entry = entries[index];
          rows.push(
            clip(entry.initiatorType || entry.entryType, 40),
            clip(entry.name, chars),
            String(entry.responseStatus || 0),
            String(Math.round(entry.duration || 0)),
            String(entry.transferSize || entry.encodedBodySize || 0)
          );
        }
        return { rows: rows, total: entries.length };
        """
}

/// The script that records the page's console, and the one piece of this feature that has to run
/// in the page's own world.
///
/// A content world has its own `console` object, so wrapping Bloom's would hear nothing the page
/// says. What is wrapped here is the page's, which the page can see, call and replace. That is
/// acceptable for what it carries, and it is why the lines arrive as untrusted text: a page can
/// write anything it likes into its own console, including lines that look like errors from
/// somewhere else.
///
/// **It is installed the first time an agent asks for the console, not when the pane opens.**
/// Wrapping `console.log` moves where Web Inspector says a message came from, onto this script's
/// line rather than the page's, and a person debugging their own dev server in that inspector
/// should not lose that because an agent might one day ask. The cost is that the first call hears
/// only what is logged after it, which the tool says, and a reload hears the page from the start.
public enum BrowserConsoleScript {
    /// The message handler the script posts to.
    public static let handlerName = "bloomConsole"

    public static let source = """
        (function () {
          if (window.__bloomConsole) { return; }
          Object.defineProperty(window, "__bloomConsole", { value: true });
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!handler) { return; }
          const post = (level, text) => {
            try {
              handler.postMessage({ level: level, text: String(text).slice(0, \(BrowserConsoleLog.textLimit)) });
            } catch (error) {
              // The handler went with the pane. The page's own console call still goes through.
            }
          };
          const describe = (value) => {
            if (typeof value === "string") { return value; }
            if (value instanceof Error) { return value.stack ? value.message + "\\n" + value.stack : String(value); }
            try { const json = JSON.stringify(value); return json === undefined ? String(value) : json; } catch (error) { return String(value); }
          };
          ["log", "info", "warn", "error", "debug"].forEach((level) => {
            const original = console[level];
            if (typeof original !== "function") { return; }
            console[level] = function () {
              post(level, Array.prototype.map.call(arguments, describe).join(" "));
              return original.apply(this, arguments);
            };
          });
          window.addEventListener("error", (event) => {
            const where = event.filename ? " (" + event.filename + ":" + event.lineno + ")" : "";
            post("error", "Uncaught " + (event.message || "error") + where);
          });
          window.addEventListener("unhandledrejection", (event) => {
            post("error", "Unhandled promise rejection: " + describe(event.reason));
          });
        })();
        """
}

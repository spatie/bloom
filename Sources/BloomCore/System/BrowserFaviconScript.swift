import Foundation

/// The two things Bloom asks a page about its own icon.
///
/// **Nothing from outside this file is ever put into either string.** They are function bodies for
/// `callAsyncJavaScript`, which passes named arguments as real JavaScript values rather than
/// splicing characters into source, so the numbers arrive as numbers and the address of the icon
/// never travels back in at all: the second call names the declaration by its position in the
/// first call's list. `BrowserPageScript` keeps the same promise by having no case that carries a
/// string, and the argument at the head of that file is the argument for this one.
///
/// **They run in `WKContentWorld.defaultClient`, not the page's own world.** A content world
/// shares the DOM and not the globals, so the `<link>` read is the real one while
/// `document.querySelectorAll`, `Image` and `HTMLCanvasElement.prototype.toDataURL` are the ones
/// WebKit shipped. In the page's world a site is free to replace all three and answer with
/// whatever it likes, and the answer ends up drawn inside Bloom's own chrome.
///
/// **The page rasterises, Bloom does not decode.** `image` draws the icon into a canvas Bloom
/// sized and hands back a PNG of that, so the file the server sent is decoded by WebKit in
/// WebKit's own sandbox and never by this process. An `.ico` with a hostile header, an SVG with a
/// script in it and a two hundred megapixel PNG are all somebody else's problem, and the bytes
/// that arrive are always a small PNG whatever the site serves.
public enum BrowserFaviconScript {
    /// Which elements count, in CSS's own words. `~=` is a whitespace token match, so
    /// `rel="shortcut icon"` is found and `rel="mask-icon"`, a pinned tab silhouette rather than a
    /// mark, is not.
    ///
    /// Shared, because the second script indexes into the list the first produced and two
    /// selectors that drifted apart would fetch a different element from the one chosen.
    private static let selector = """
        link[rel~='icon'], link[rel~='apple-touch-icon'], link[rel~='apple-touch-icon-precomposed']
        """

    /// Every icon the page declares, four strings each: rel, sizes, type, and the resolved href.
    ///
    /// Which of them is worth having is `BrowserFavicon.choose`, in Swift, where it is a rule with
    /// cases and a test rather than a sort buried in a string.
    public static let links = """
        const found = document.querySelectorAll("\(selector)");
        const out = [];
        for (let i = 0; i < found.length && out.length < limit * 4; i += 1) {
          const link = found[i];
          out.push(
            String(link.rel || "").slice(0, chars),
            String(link.getAttribute("sizes") || "").slice(0, chars),
            String(link.type || "").slice(0, chars),
            String(link.href || "").slice(0, chars)
          );
        }
        return out;
        """

    /// One of those icons, drawn into a square canvas and handed back as a PNG data URL, with the
    /// href it was taken from so the caller can check it against the one it chose.
    ///
    /// `crossOrigin = "anonymous"` is the line with a consequence. A same origin request still
    /// carries the page's cookies, so an icon behind a login loads as it does for the page itself;
    /// a request to another host is sent without them, so looking at a page never sends the
    /// owner's session to a third party for a picture. The cost is that a host serving its icons
    /// from a CDN with no `Access-Control-Allow-Origin` header cannot be read: the canvas is
    /// tainted, `toDataURL` throws, and the tab keeps its globe.
    public static let image = """
        const found = document.querySelectorAll("\(selector)");
        const link = found[index];
        if (!link) { return null; }
        const href = String(link.href || "").slice(0, chars);
        if (!href) { return null; }

        const image = new Image();
        image.crossOrigin = "anonymous";
        const loaded = await new Promise((resolve) => {
          image.onload = () => resolve(true);
          image.onerror = () => resolve(false);
          setTimeout(() => resolve(false), timeout);
          image.src = href;
        });
        if (!loaded) { return null; }

        let width = image.naturalWidth || image.width || 0;
        let height = image.naturalHeight || image.height || 0;
        // An SVG with no width and no height of its own measures zero, and something zero wide
        // draws nothing. It scales to whatever it is asked for, so it is asked for all of it.
        if (width <= 0 || height <= 0) { width = size; height = size; }

        const canvas = document.createElement("canvas");
        canvas.width = size;
        canvas.height = size;
        const context = canvas.getContext("2d");
        if (!context) { return null; }

        // Letterboxed rather than stretched. A wordmark four times as wide as it is tall is a real
        // thing to find in a `<link rel=icon>`, and squashing it would put a distorted picture in
        // the strip instead of a small one.
        const scale = Math.min(size / width, size / height);
        const drawnWidth = Math.max(1, Math.round(width * scale));
        const drawnHeight = Math.max(1, Math.round(height * scale));
        context.drawImage(
          image,
          Math.round((size - drawnWidth) / 2),
          Math.round((size - drawnHeight) / 2),
          drawnWidth,
          drawnHeight
        );

        let encoded = "";
        try {
          encoded = canvas.toDataURL("image/png");
        } catch (error) {
          return null;
        }
        return [href, encoded];
        """
}

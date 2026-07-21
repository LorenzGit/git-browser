import WebKit

/// App-owned presentation rules applied to documents shown in the web preview.
public enum WebPreviewStyle {
    /// Keeps repository images inside the preview while preserving their
    /// aspect ratio. Canvas-mode design documents often represent screenshots
    /// as fixed-width DOM frames instead of `<img>` elements, so their top-level
    /// cards are proportionally scaled to the available viewport width too.
    /// The repository content returned by `RepoSchemeHandler` stays unchanged.
    public static func install(in configuration: WKWebViewConfiguration) {
        let source = """
        (() => {
          const style = document.createElement('style');
          style.id = 'git-browser-contained-visuals';
          style.textContent = `
            img {
              max-width: min(100%, 100vw) !important;
              height: auto !important;
              box-sizing: border-box !important;
            }
          `;
          (document.head || document.documentElement).appendChild(style);

          const canvasMode = document.querySelector(
            'meta[name="design_doc_mode"][content="canvas"]'
          );
          if (!canvasMode) return;

          const selector = '.dv-opt > .dv-card, .dv-opt > .dv-card-light';
          const authoredZoom = new WeakMap();

          const restoreZoom = (frame) => {
            if (!authoredZoom.has(frame)) {
              authoredZoom.set(frame, {
                value: frame.style.getPropertyValue('zoom'),
                priority: frame.style.getPropertyPriority('zoom')
              });
            }
            const original = authoredZoom.get(frame);
            if (original.value) {
              frame.style.setProperty('zoom', original.value, original.priority);
            } else {
              frame.style.removeProperty('zoom');
            }
          };

          const fitCanvasFrames = () => {
            const frames = Array.from(document.querySelectorAll(selector));
            frames.forEach(restoreZoom);

            // Measure all frames at their authored size before applying zoom.
            void document.documentElement.offsetWidth;
            const viewportWidth = document.documentElement.clientWidth;

            frames.forEach((frame) => {
              const rect = frame.getBoundingClientRect();
              const section = frame.closest('.dv-turn');
              const rightPadding = section
                ? parseFloat(getComputedStyle(section).paddingRight) || 0
                : 0;
              const documentLeft = rect.left + window.scrollX;
              const availableWidth = viewportWidth - documentLeft - rightPadding;

              if (availableWidth >= 80 && rect.width > availableWidth + 0.5) {
                const scale = availableWidth / rect.width;
                frame.style.setProperty('zoom', scale.toFixed(6), 'important');
              }
            });
          };

          let fitTimer = 0;
          const scheduleFit = () => {
            clearTimeout(fitTimer);
            fitTimer = setTimeout(fitCanvasFrames, 0);
          };

          // Design Components replace their hidden <x-dc> source with a
          // rendered #dc-root asynchronously. Watch for that hydration so we
          // fit the visible frames rather than the hidden source template.
          const observer = new MutationObserver(scheduleFit);
          observer.observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['data-dc-canvas']
          });

          fitCanvasFrames();
          setTimeout(fitCanvasFrames, 250);
          window.addEventListener('resize', scheduleFit);
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }
}

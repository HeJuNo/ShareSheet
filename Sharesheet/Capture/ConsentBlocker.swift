import WebKit

/// Removes cookie and consent banners from a page before it is captured, without accepting or rejecting anything:
/// clicking a button would set cookies, which is not wanted. Banners are found by the selectors of common consent
/// managers and by their look: a fixed, sticky or modal element, also inside an open shadow root, that talks about
/// cookies or consent and offers a button to answer. Once a banner is gone, its backdrop and the scroll lock it set go with it.
enum ConsentBlocker {
    /// Watches the page from load on, since consent managers usually appear a moment later.
    @MainActor static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Removes what is on the page now; the capturer calls this right before the shot.
    static let removeNow = "window.__sharesheetRemoveConsent && window.__sharesheetRemoveConsent()"

    private static let script = """
        (function () {
          var selectors = [
            '#onetrust-consent-sdk', '#CybotCookiebotDialog', '#CybotCookiebotDialogBodyUnderlay', '#usercentrics-root',
            '#usercentrics-cmp-ui', '#didomi-host', '.qc-cmp2-container', '#BorlabsCookieBox', '.cc-window',
            '.cc-banner', '.klaro', '[id^="sp_message_container"]', '.cky-consent-container', '.cky-overlay',
            '#cmplz-cookiebanner-container', '#truste-consent-track', '.truste_overlay', '#iubenda-cs-banner',
            '.osano-cm-window', '#termly-code-snippet-support', '#cookie-law-info-bar', '.cli-modal-backdrop',
            '#cookiescript_injected', '.fc-consent-root', '#tarteaucitronRoot', '#axeptio_overlay',
            '#cookieshield-widget-root', '[data-testid="cookie-policy-manage-dialog"]', '[data-cookiebanner]'
          ];
          var topic = /cookie|consent|einwillig|privatsph|gdpr|dsgvo/i;
          var answer = /akzept|accept|agree|zustimm|ablehn|reject|decline|allow|erlaub|einverstanden|verstanden|got it|^ok$|anpass|customi|manage|einstellung|settings|speicher|save|weiter|continue/i;

          function answers(e) {
            var buttons = e.querySelectorAll('button, [role="button"], a, input[type="button"], input[type="submit"]');
            for (var i = 0; i < buttons.length; i++) {
              var label = (buttons[i].textContent || buttons[i].value || '').trim();
              if (answer.test(label)) { return true; }
            }
            return false;
          }

          function floats(e) {
            var p = getComputedStyle(e).position;
            return p === 'fixed' || p === 'sticky' || e.getAttribute('aria-modal') === 'true'
              || e.getAttribute('role') === 'dialog' || (e.tagName === 'DIALOG' && e.open);
          }

          // Cheapest test first: reading the text of every element on a large page would take quadratic time.
          function isBanner(e) {
            if (!floats(e)) { return false; }
            var text = e.textContent || '';
            return text.length < 3000 && topic.test(text) && answers(e);
          }

          function hasBanner(root) {
            var inner = root.querySelectorAll('*');
            for (var i = 0; i < inner.length; i++) {
              if (isBanner(inner[i]) || (inner[i].shadowRoot && hasBanner(inner[i].shadowRoot))) { return true; }
            }
            return false;
          }

          function remove() {
            var removed = 0;
            selectors.forEach(function (s) {
              document.querySelectorAll(s).forEach(function (e) { e.remove(); removed++; });
            });
            var all = document.querySelectorAll('body *');
            for (var i = 0; i < all.length; i++) {
              var e = all[i];
              if (!e.isConnected) { continue; }
              // A banner drawn inside a shadow root goes with its host.
              if (isBanner(e) || (e.shadowRoot && hasBanner(e.shadowRoot))) { e.remove(); removed++; }
            }
            if (removed === 0) { return 0; }
            // Backdrops: empty fixed layers covering most of the screen.
            document.querySelectorAll('body *').forEach(function (e) {
              if (getComputedStyle(e).position !== 'fixed' || (e.textContent || '').trim().length > 0) { return; }
              var r = e.getBoundingClientRect();
              if (r.width * r.height >= 0.8 * window.innerWidth * window.innerHeight) { e.remove(); }
            });
            [document.documentElement, document.body].forEach(function (e) {
              if (!e) { return; }
              e.style.setProperty('overflow', 'visible', 'important');
              if (getComputedStyle(e).position === 'fixed') { e.style.setProperty('position', 'static', 'important'); }
            });
            return removed;
          }

          window.__sharesheetRemoveConsent = remove;
          var pending = null, runs = 0;
          new MutationObserver(function () {
            if (pending || runs >= 40) { return; }
            pending = setTimeout(function () { pending = null; runs++; remove(); }, 200);
          }).observe(document.documentElement, { childList: true, subtree: true });
          remove();
        })();
        """
}

// Haists IT Consulting — Home Assistant favicon override
// OPS-586 Section A
//
// Loaded via extra_module_url in frontend: configuration block.
// HA serves files from config/www/ at /local/ path.
//
// This replaces the HA default blue-house favicon with the Haists H+I lockup.
// Source SVG: /local/favicon-32.svg (deployed from ansible/roles/ha-lxc/files/www/)
//
// Ref: https://www.home-assistant.io/integrations/frontend/#loading-extra-javascript

(function () {
  function setHaistsFavicon() {
    // Remove existing favicon link tags (HA default blue house)
    document.querySelectorAll("link[rel~='icon']").forEach(function (el) {
      el.parentNode.removeChild(el);
    });

    // Insert Haists favicon
    var link = document.createElement("link");
    link.rel = "icon";
    link.type = "image/svg+xml";
    link.href = "/local/favicon-32.svg";
    document.head.appendChild(link);

    // Also update the PWA manifest icon href if accessible
    var manifestLink = document.querySelector("link[rel='manifest']");
    if (manifestLink) {
      // Cannot modify the manifest file directly; favicon link above is sufficient
      // for browser tab display.
    }
  }

  // Run once DOM is ready; HA loads async so we retry briefly
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setHaistsFavicon);
  } else {
    setHaistsFavicon();
  }

  // HA is a SPA — re-apply on navigation to catch any HA re-injects
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      setHaistsFavicon();
    }
  });
})();

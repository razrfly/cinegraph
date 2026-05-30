/**
 * ClerkAuthUI Hook
 *
 * Handles client-side hydration of auth UI elements for CDN-cached pages.
 *
 * CDN Caching Strategy:
 * We cache the SAME HTML for everyone on public pages. Auth UI is hydrated
 * client-side using Clerk's JavaScript SDK. This allows Cloudflare to cache
 * pages effectively since we don't vary by auth cookies.
 *
 * See: https://github.com/razrfly/eventasaurus/issues/2970
 *
 * Usage:
 *   <div id="clerk-auth-desktop" phx-hook="ClerkAuthUI" data-type="desktop">
 *     <!-- Loading skeleton shown initially -->
 *     <div data-clerk-loading>...</div>
 *     <!-- Authenticated UI (hidden until Clerk confirms auth) -->
 *     <div data-clerk-signed-in class="hidden">...</div>
 *     <!-- Anonymous UI (hidden until Clerk confirms no auth) -->
 *     <div data-clerk-signed-out class="hidden">...</div>
 *   </div>
 */

import { initClerkClient, getCurrentUser } from "../auth/clerk-manager";

const ClerkAuthUI = {
  mounted() {
    this.type = this.el.dataset.type || "default";
    // Store bound handler reference for cleanup
    this.authChangeHandler = (e) => this.hydrateUI(e.detail.user);
    this.initAuthUI();
  },

  async initAuthUI() {
    try {
      // Check for server-side auth first (Phoenix session, dev mode login)
      // This is set in root.html.heex when conn.assigns[:user] exists
      if (window.currentUser) {
        console.log("[ClerkAuthUI] Using server-side auth:", window.currentUser);
        this.hydrateUI(window.currentUser);
        // Still initialize Clerk for sign-out functionality, but don't wait
        initClerkClient().catch(() => {});
        return;
      }

      // Fall back to Clerk client-side auth
      await initClerkClient();

      // Get current auth state from Clerk
      const user = getCurrentUser();

      // Hydrate the UI based on auth state
      this.hydrateUI(user);

      // Listen for auth state changes (using stored handler for cleanup)
      window.addEventListener("clerk:auth-change", this.authChangeHandler);
    } catch (error) {
      console.error("[ClerkAuthUI] Error initializing:", error);
      // On error, show anonymous UI as fallback
      this.hydrateUI(null);
    }
  },

  hydrateUI(user) {
    const loadingEl = this.el.querySelector("[data-clerk-loading]");
    const signedInEl = this.el.querySelector("[data-clerk-signed-in]");
    const signedOutEl = this.el.querySelector("[data-clerk-signed-out]");

    // Hide loading skeleton
    if (loadingEl) {
      loadingEl.classList.add("hidden");
    }

    if (user) {
      // User is authenticated
      if (signedInEl) {
        signedInEl.classList.remove("hidden");
        // Populate user info if there are data placeholders
        this.populateUserInfo(signedInEl, user);
      }
      if (signedOutEl) {
        signedOutEl.classList.add("hidden");
      }
    } else {
      // User is not authenticated
      if (signedInEl) {
        signedInEl.classList.add("hidden");
      }
      if (signedOutEl) {
        signedOutEl.classList.remove("hidden");
      }
    }
  },

  populateUserInfo(container, user) {
    // Handle both Clerk user format and Phoenix session user format
    // Clerk: { primaryEmailAddress: { emailAddress: "..." }, firstName, imageUrl }
    // Phoenix: { email: "...", name: "...", id: "..." }

    // Populate email
    const emailEls = container.querySelectorAll("[data-clerk-user-email]");
    const email = user.primaryEmailAddress?.emailAddress || user.email || "";
    emailEls.forEach((el) => {
      el.textContent = email;
    });

    // Populate avatar - use Clerk imageUrl, or generate a DiceBear avatar from email
    const avatarEls = container.querySelectorAll("[data-clerk-user-avatar]");
    const displayName = user.firstName || user.name || user.username || email || "User";
    avatarEls.forEach((el) => {
      if (user.imageUrl) {
        el.src = user.imageUrl;
      } else {
        // Generate a DiceBear avatar using email as seed (matches server-side avatar_helper.ex)
        el.src = `https://api.dicebear.com/9.x/dylan/svg?seed=${encodeURIComponent(email)}&size=32`;
      }
      el.alt = displayName;
    });

    // Populate name (support both Clerk's firstName and Phoenix's name)
    const nameEls = container.querySelectorAll("[data-clerk-user-name]");
    const name = user.firstName || user.name || user.username || "";
    nameEls.forEach((el) => {
      el.textContent = name;
    });
  },

  destroyed() {
    // Remove event listener to prevent memory leaks during LiveView navigation
    if (this.authChangeHandler) {
      window.removeEventListener("clerk:auth-change", this.authChangeHandler);
    }
  }
};

export default ClerkAuthUI;

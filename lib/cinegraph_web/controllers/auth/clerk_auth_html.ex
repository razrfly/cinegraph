defmodule CinegraphWeb.Auth.ClerkAuthHTML do
  @moduledoc """
  HTML templates for Clerk authentication pages.

  These templates render Clerk's pre-built UI components (SignIn, SignUp,
  UserProfile) via Clerk.js inside `phx-update="ignore"` containers so LiveView
  never touches the Clerk-managed DOM.
  """
  use CinegraphWeb, :html

  @doc """
  Clerk sign-in page.
  """
  def clerk_login(assigns) do
    ~H"""
    <div class="mx-auto max-w-md px-4 py-12 md:py-16">
      <div id="clerk-sign-in" class="flex justify-center" phx-update="ignore">
        <div class="text-center text-gray-500 py-8">
          <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900 mx-auto mb-4">
          </div>
          Loading sign-in...
        </div>
      </div>

      <script>
        (function() {
          const containerId = 'clerk-sign-in';
          let mounted = false;
          let retries = 0;
          const maxRetries = 100; // ~10s at 100ms; stop polling if Clerk never loads

          async function initClerkSignIn() {
            if (mounted) return;
            const container = document.getElementById(containerId);
            if (!container) return;
            if (!window.Clerk) {
              if (retries++ < maxRetries) setTimeout(initClerkSignIn, 100);
              else console.error('Clerk.js failed to load');
              return;
            }

            try {
              await window.Clerk.load();
              const returnTo = <%= raw(Jason.encode!(@return_to, escape: :html_safe)) %>;

              if (window.Clerk.user) {
                window.location.href = returnTo || '/';
                return;
              }

              if (!mounted) {
                mounted = true;
                container.innerHTML = '';
                const callbackUrl = returnTo
                  ? '/auth/callback?return_to=' + encodeURIComponent(returnTo)
                  : '/auth/callback';

                window.Clerk.mountSignIn(container, {
                  afterSignInUrl: callbackUrl,
                  afterSignUpUrl: callbackUrl,
                  signUpUrl: '<%= ~p"/auth/register" %>',
                  appearance: {
                    elements: {
                      rootBox: 'w-full flex justify-center',
                      card: 'shadow-none border border-gray-200 rounded-lg'
                    }
                  }
                });
              }
            } catch (error) {
              console.error('Error mounting Clerk SignIn:', error);
            }
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initClerkSignIn);
          } else {
            initClerkSignIn();
          }
        })();
      </script>
    </div>
    """
  end

  @doc """
  Clerk sign-up page.
  """
  def clerk_register(assigns) do
    ~H"""
    <div class="mx-auto max-w-md px-4 py-12 md:py-16">
      <div id="clerk-sign-up" class="flex justify-center" phx-update="ignore">
        <div class="text-center text-gray-500 py-8">
          <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900 mx-auto mb-4">
          </div>
          Loading registration...
        </div>
      </div>

      <script>
        (function() {
          const containerId = 'clerk-sign-up';
          let mounted = false;
          let retries = 0;
          const maxRetries = 100; // ~10s at 100ms; stop polling if Clerk never loads

          async function initClerkSignUp() {
            if (mounted) return;
            const container = document.getElementById(containerId);
            if (!container) return;
            if (!window.Clerk) {
              if (retries++ < maxRetries) setTimeout(initClerkSignUp, 100);
              else console.error('Clerk.js failed to load');
              return;
            }

            try {
              await window.Clerk.load();

              if (window.Clerk.user) {
                window.location.href = '/';
                return;
              }

              if (!mounted) {
                mounted = true;
                container.innerHTML = '';
                window.Clerk.mountSignUp(container, {
                  afterSignInUrl: '<%= ~p"/auth/callback" %>',
                  afterSignUpUrl: '<%= ~p"/auth/callback" %>',
                  signInUrl: '<%= ~p"/auth/login" %>',
                  appearance: {
                    elements: {
                      rootBox: 'w-full flex justify-center',
                      card: 'shadow-none border border-gray-200 rounded-lg'
                    }
                  }
                });
              }
            } catch (error) {
              console.error('Error mounting Clerk SignUp:', error);
            }
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initClerkSignUp);
          } else {
            initClerkSignUp();
          }
        })();
      </script>
    </div>
    """
  end

  @doc """
  Clerk user profile page.
  """
  def clerk_profile(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-12 md:py-16">
      <.header class="mb-8">
        Account Settings
        <:subtitle>Manage your account settings and profile</:subtitle>
      </.header>

      <div id="clerk-user-profile" class="flex justify-center" phx-update="ignore">
        <div class="text-center text-gray-500 py-8">
          <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900 mx-auto mb-4">
          </div>
          Loading profile...
        </div>
      </div>

      <script>
        (function() {
          const containerId = 'clerk-user-profile';
          let mounted = false;
          let retries = 0;
          const maxRetries = 100; // ~10s at 100ms; stop polling if Clerk never loads

          async function initClerkUserProfile() {
            if (mounted) return;
            const container = document.getElementById(containerId);
            if (!container) return;
            if (!window.Clerk) {
              if (retries++ < maxRetries) setTimeout(initClerkUserProfile, 100);
              else console.error('Clerk.js failed to load');
              return;
            }

            try {
              await window.Clerk.load();

              if (!window.Clerk.user) {
                window.location.href = '<%= ~p"/auth/login" %>';
                return;
              }

              if (!mounted) {
                mounted = true;
                container.innerHTML = '';
                window.Clerk.mountUserProfile(container, {
                  appearance: {
                    elements: {
                      rootBox: 'w-full',
                      card: 'shadow-none border border-gray-200 rounded-lg'
                    }
                  }
                });
              }
            } catch (error) {
              console.error('Error mounting Clerk UserProfile:', error);
            }
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initClerkUserProfile);
          } else {
            initClerkUserProfile();
          }
        })();
      </script>
    </div>
    """
  end
end

import Config

config :appsignal, :config,
  otp_app: :cinegraph,
  name: "cinegraph",
  push_api_key: System.get_env("APPSIGNAL_PUSH_API_KEY"),
  env: Mix.env()

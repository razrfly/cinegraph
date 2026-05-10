import Config

config :appsignal, :config,
  otp_app: :cinegraph,
  name: "cinegraph",
  env: config_env()

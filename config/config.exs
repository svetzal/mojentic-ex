import Config

# Configure Logger to accept custom metadata keys
config :logger, :default_formatter,
  metadata: [
    :max_iterations,
    :user_request,
    :result,
    :reason
  ]

# Import environment-specific config
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end

defmodule Atlas.Config do
  @moduledoc false
  @app :atlas

  def mix_env, do: Application.get_env(@app, :mix_env)

  def content_backend, do: Application.get_env(@app, :content_backend, Atlas.Backend.S3)
  def content_bucket, do: Application.get_env(@app, :content_bucket)

  def state_backend, do: Application.get_env(@app, :state_backend, Atlas.Backend.S3)
  def state_bucket, do: Application.get_env(@app, :state_bucket)
  def state_key, do: Application.get_env(@app, :state_key)
end

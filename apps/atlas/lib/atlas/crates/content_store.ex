defmodule Atlas.Crates.ContentStore do
  @moduledoc false
  alias Atlas.Config

  def content_key(app_name, content_id) do
    "crates/#{to_string(app_name)}/content/#{content_id}"
  end

  def head_content(bucket, app_name, content_id, opts \\ []) do
    backend(opts).head(bucket, content_key(app_name, content_id), opts)
  end

  def get_content(bucket, app_name, content_id, opts \\ []) do
    backend(opts).get(bucket, content_key(app_name, content_id), opts)
  end

  def put_content(bucket, app_name, content_id, data, opts \\ []) do
    backend(opts).put_new(bucket, content_key(app_name, content_id), data, opts)
  end

  def resolve_bucket!(opts) do
    Keyword.get(opts, :bucket) || Config.content_bucket() ||
      raise "Atlas content bucket is not configured: set :atlas, :content_bucket or pass :bucket"
  end

  defp backend(opts) do
    Keyword.get(opts, :content_backend, Config.content_backend())
  end
end

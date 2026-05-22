defmodule Atlas.Backend.S3 do
  alias AWS.S3

  @behaviour Atlas.Backend

  @impl true
  def head(bucket, key, opts) do
    S3.head_object(bucket, key, opts)
  end

  @impl true
  def get(bucket, key, opts) do
    S3.get_object(bucket, key, opts)
  end

  @impl true
  def put_new(bucket, key, body, opts) do
    S3.put_new_object(bucket, key, body, opts)
  end
end

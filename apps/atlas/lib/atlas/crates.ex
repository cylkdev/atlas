defmodule Atlas.Crates do
  @moduledoc """
  ## Getting Started

  ```
  {:ok, release} = Atlas.Crates.create_crate("my-app", "0.1.0")
  {:ok, release} = Atlas.Crates.find_crate_by_name("my-app")
  {:ok, artifact} = Atlas.Crates.publish_content(release, "data", "0.1.0")
  {:ok, %{content_id: content_id, version: version, bucket: bucket, key: key}} =
    Atlas.Crates.find_latest_release("my-app")
  ```
  """
  alias AtlasSchemas.Crates
  alias Atlas.Crates.ContentStore

  def find_crate_by_name(name, opts \\ []) do
    Crates.find_crate(%{name: name}, opts)
  end

  def download_content(crate_name, content_id, output_dir, opts \\ []) do
    with {:ok, data} <- get_content(crate_name, content_id, opts) do
      if File.dir?(output_dir) do
        File.write!(Path.join(output_dir, "release.tar.gz"), data)
        :ok
      else
        {:error, ErrorMessage.bad_request("not a directory", %{output_dir: output_dir})}
      end
    end
  end

  def head_content(crate_name, content_id, opts \\ []) do
    bucket = ContentStore.resolve_bucket!(opts)

    with {:ok, crate} <- find_crate_by_name(crate_name, opts) do
      ContentStore.head_content(bucket, crate.name, content_id, opts)
    end
  end

  def get_content(crate_name, content_id, opts \\ []) do
    bucket = ContentStore.resolve_bucket!(opts)

    with {:ok, crate} <- find_crate_by_name(crate_name, opts),
         {:ok, data} <- ContentStore.get_content(bucket, crate.name, content_id, opts) do
      {:ok, data}
    end
  end

  def create_crate(name, version, opts \\ []) do
    with {:error, %{code: :not_found}} <- Crates.find_crate(%{name: name}, opts),
         {:error, changeset} <- Crates.create_crate(%{name: name, version: version}, opts) do
      {:error,
       ErrorMessage.internal_server_error("failed to create release", %{
         name: name,
         version: version,
         changeset: changeset
       })}
    end
  end

  def set_current_release_to_version(%AtlasSchemas.Crates.Crate{} = crate, version, opts \\ []) do
    with {:ok, artifact} <- Crates.find_artifact(%{crate_id: crate.id, version: version}, opts),
         {:ok, crate} <- set_current_release(crate, artifact.content_id, artifact.version, opts) do
      {:ok, %{artifact: artifact, crate: crate}}
    end
  end

  def set_current_release(
        %AtlasSchemas.Crates.Crate{} = crate,
        content_id,
        content_version,
        opts
      ) do
    Crates.update_crate(
      crate,
      %{current_content_id: content_id, current_version: content_version},
      opts
    )
  end

  def find_latest_release(crate_name, opts \\ []) do
    with {:ok, crate} <- find_crate_by_name(crate_name, opts) do
      case crate.current_content_id do
        nil ->
          {:ok, %{content_id: nil, version: nil, bucket: nil, key: nil}}

        content_id ->
          with {:ok, artifact} <-
                 Crates.find_artifact(%{crate_id: crate.id, content_id: content_id}, opts) do
            {:ok,
             %{
               content_id: artifact.content_id,
               version: artifact.version,
               bucket: artifact.bucket,
               key: artifact.key
             }}
          end
      end
    end
  end

  def publish_content(
        %AtlasSchemas.Crates.Crate{} = crate,
        content,
        content_version,
        opts \\ []
      ) do
    bucket = ContentStore.resolve_bucket!(opts)
    content_id = hash_sha256(content)

    with :ok <- ensure_content_exists(bucket, crate.name, content_id, content, opts),
         {:ok, meta} <- ContentStore.head_content(bucket, crate.name, content_id, opts),
         {:ok, artifact} <-
           upsert_artifact(crate, bucket, content_id, content_version, meta.etag, opts),
         {:ok, _crate} <- set_current_release(crate, content_id, content_version, opts) do
      {:ok, %{artifact: artifact}}
    end
  end

  defp upsert_artifact(
         %AtlasSchemas.Crates.Crate{} = crate,
         bucket,
         content_id,
         content_version,
         etag,
         opts
       ) do
    key = ContentStore.content_key(crate.name, content_id)

    with {:error, %{code: :not_found}} <-
           Crates.find_artifact(%{crate_id: crate.id, content_id: content_id}, opts) do
      Crates.create_artifact(
        %{
          crate_id: crate.id,
          content_id: content_id,
          version: content_version,
          bucket: bucket,
          key: key,
          etag: etag
        },
        opts
      )
    else
      {:ok, artifact} ->
        Crates.update_artifact(
          artifact,
          %{version: content_version, bucket: bucket, key: key, etag: etag},
          opts
        )

      error ->
        error
    end
  end

  defp ensure_content_exists(bucket, app_name, content_id, data, opts) do
    case ContentStore.put_content(bucket, app_name, content_id, data, opts) do
      {:ok, _} -> :ok
      {:error, %{code: :conflict}} -> :ok
      error -> error
    end
  end

  defp hash_sha256(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16()
  end
end

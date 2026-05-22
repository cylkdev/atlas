defmodule Atlas.Backend do
  @moduledoc false
  @callback head(bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback get(bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback put_new(bucket :: String.t(), key :: String.t(), body :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}
end

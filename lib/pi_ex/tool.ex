defmodule PiEx.Tool do
  @moduledoc "Behaviour for PiEx tools that the LLM can invoke."

  @type content :: [
          %{type: :text, text: String.t()}
          | %{type: :image, media_type: String.t(), data: String.t()}
        ]
  @type context :: %{cwd: String.t()}
  @type result :: {:ok, content()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map(), context :: context()) :: result()
end

defmodule PiEx.Tools do
  @moduledoc "Built-in tool collections."

  @doc "Returns all 4 coding tools as a list of modules implementing PiEx.Tool."
  def coding_tools do
    [PiEx.Tools.Read, PiEx.Tools.Write, PiEx.Tools.Edit, PiEx.Tools.Bash]
  end

  @doc "Convert a PiEx.Tool module to a ReqLLM.Tool struct for LLM use."
  def to_req_llm_tool(tool_module) do
    ReqLLM.Tool.new!(
      name: tool_module.name(),
      description: tool_module.description(),
      parameter_schema: tool_module.parameters(),
      callback: fn args ->
        case tool_module.execute(args, %{cwd: File.cwd!()}) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:ok, reason}
        end
      end
    )
  end
end

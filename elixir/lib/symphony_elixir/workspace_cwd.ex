defmodule SymphonyElixir.WorkspaceCwd do
  @moduledoc """
  Validates that a local agent cwd stays strictly inside the configured
  workspace root (no root itself, no symlink escape).
  """

  alias SymphonyElixir.{Config, PathSafety}

  @spec validate_local(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_local(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- canonicalize(expanded_workspace),
         {:ok, canonical_root} <- canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    end
  end

  defp canonicalize(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, {:path_canonicalize_failed, failed_path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, failed_path, reason}}
    end
  end
end

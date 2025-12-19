defmodule Mail.Parsers.GMime.NIF do
  @moduledoc false
  # Internal module for GMime NIF interface
  # Do not use directly - use Mail.Parsers.GMime instead

  @on_load :load_nif

  @doc false
  def load_nif do
    nif_path =
      case :code.priv_dir(:mail) do
        {:error, :bad_name} ->
          # Development mode fallback
          case :filelib.is_dir(~c"priv") do
            true -> :filename.join(~c"priv", ~c"gmime_nif")
            false -> :filename.join([~c".", ~c"priv", ~c"gmime_nif"])
          end

        path ->
          :filename.join(path, ~c"gmime_nif")
      end

    case :erlang.load_nif(nif_path, 0) do
      :ok ->
        :ok

      {:error, {:load_failed, reason}} ->
        IO.warn("""
        Failed to load GMime NIF: #{reason}

        Make sure GMime 3.0+ is installed:
          Ubuntu/Debian: sudo apt-get install libgmime-3.0-dev
          macOS: brew install gmime

        Then recompile: mix deps.compile mail --force
        """)

        {:error, :nif_load_failed}

      {:error, reason} ->
        IO.warn("Failed to load GMime NIF: #{inspect(reason)}")
        {:error, :nif_load_failed}
    end
  end

  @doc false
  def parse_string_nif(_email_binary, _opts) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc false
  def parse_stream_nif(_file_path, _opts) do
    :erlang.nif_error(:nif_not_loaded)
  end
end

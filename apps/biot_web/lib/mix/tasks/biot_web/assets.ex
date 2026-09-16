defmodule Mix.Tasks.BiotWeb.Assets do
  @moduledoc "Copies browser assets that are not handled by an asset bundler."

  use Mix.Task

  @source_dir Path.expand("../../../../assets/vendor", __DIR__)
  @destination_dir Path.expand("../../../../priv/static/assets/vendor", __DIR__)
  @stylesheet_source Path.expand("../../../../assets/css/app.css", __DIR__)
  @stylesheet_destination Path.expand("../../../../priv/static/assets/css/app.css", __DIR__)
  @vendor_assets [
    "ghostty-web-0.4.0.js",
    "ghostty-vt-0.4.0.wasm",
    "ghostty-web-0.4.0.LICENSE"
  ]

  @impl Mix.Task
  def run(_args) do
    File.mkdir_p!(@destination_dir)
    File.mkdir_p!(Path.dirname(@stylesheet_destination))

    Enum.each(@vendor_assets, &copy_asset!/1)
    copy_file!(@stylesheet_source, @stylesheet_destination)
  end

  defp copy_asset!(filename) do
    source = Path.join(@source_dir, filename)
    destination = Path.join(@destination_dir, filename)

    unless File.regular?(source) do
      Mix.raise("required web asset source is missing: #{source}")
    end

    File.cp!(source, destination)
  end

  defp copy_file!(source, destination) do
    unless File.regular?(source) do
      Mix.raise("required web asset source is missing: #{source}")
    end

    File.cp!(source, destination)
  end
end

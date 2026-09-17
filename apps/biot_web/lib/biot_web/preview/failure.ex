defmodule BiotWeb.Preview.Failure do
  @moduledoc """
  Small self-contained pages the preview proxy renders for its own failures.

  The control host's stylesheet and scripts are not loaded here: a preview host is a different
  origin, and a failure page must not send a preview application's browser to `__Host-biot_*`
  state or to control assets. Every page is inert HTML with inline styling.
  """

  @spec response(atom(), String.t()) :: {pos_integer(), String.t()}
  def response(:not_found, _control_url) do
    {404, page("Not found", "This Biot is not published at this address.", nil)}
  end

  def response(:forbidden, control_url) do
    link = {"Open Biot", control_url}

    {403, page("No access", "You do not have access to this Biot.", link)}
  end

  def response(:unauthenticated, _control_url) do
    {401, page("Sign in required", "This request needs a valid Biot credential.", nil)}
  end

  def response(:node_unavailable, _control_url) do
    {503, page("Biot not running", "This Biot is not running right now.", nil)}
  end

  def response(:agent_unreachable, _control_url) do
    {503, page("Biot not running", "This Biot is not running right now.", nil)}
  end

  def response(:port_not_listening, _control_url) do
    {502, page("Nothing to show", "The application is not listening on this port.", nil)}
  end

  def response(:too_large, _control_url) do
    {413, page("Request too large", "This request is larger than this Biot accepts.", nil)}
  end

  def response(:too_many_streams, _control_url) do
    {503, page("Try again", "This Biot is busy. Try again in a moment.", nil)}
  end

  def response(:timeout, _control_url) do
    {503, page("Try again", "This Biot did not answer in time. Try again in a moment.", nil)}
  end

  def response(:unsupported_credential, _control_url) do
    {401, page("Sign in required", "This request needs a valid Biot credential.", nil)}
  end

  defp page(title, message, link) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{escape(title)}</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            background: #eef5f0;
            color: #082a2f;
            font-family: ui-monospace, "SFMono-Regular", "Cascadia Code", Menlo, monospace;
          }
          main { max-width: 34rem; padding: 2rem; }
          h1 { font-size: 1.25rem; margin: 0 0 0.75rem; }
          p { margin: 0 0 1rem; line-height: 1.5; }
          a { color: inherit; text-underline-offset: 0.2em; }
          @media (prefers-color-scheme: dark) {
            body { background: #082a2f; color: #eef5f0; }
          }
        </style>
      </head>
      <body>
        <main>
          <h1>#{escape(title)}</h1>
          <p>#{escape(message)}</p>
          #{link_html(link)}
        </main>
      </body>
    </html>
    """
  end

  defp link_html(nil), do: ""
  defp link_html({text, url}), do: ~s(<p><a href="#{escape(url)}">#{escape(text)}</a></p>)

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

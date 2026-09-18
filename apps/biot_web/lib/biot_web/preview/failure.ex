defmodule BiotWeb.Preview.Failure do
  @moduledoc """
  Small self-contained pages the preview proxy renders for its own failures.

  The control host's stylesheet and scripts are not loaded here: a preview host is a different
  origin, and a failure page must not send a preview application's browser to `__Host-biot_*`
  state or to control assets. Every page is inert HTML with inline styling.

  Each page is one entry of `@pages`, which is both the vocabulary of reasons the proxy can
  render and the source of every status, so a reason without a page cannot exist. The only action
  a page offers is the control host's link, because the reader is a browser that may have no CLI.
  """

  # reason => {status, title, message, link label | nil}
  @pages %{
    not_found:
      {404, "Not found", "This Biot is not published at this address. Check the address.",
       "Open Biot"},
    forbidden: {403, "No access", "You do not have access to this Biot.", "Open Biot"},
    unauthenticated:
      {401, "Sign in required",
       "This request needs a valid Biot credential. Sign in and try again.", "Sign in"},
    unsupported_credential:
      {401, "Sign in required",
       "This request needs a valid Biot credential. Sign in and try again.", "Sign in"},
    node_unavailable:
      {503, "Biot not running", "This Biot is not running right now. Ask its owner to start it.",
       "Open Biot"},
    agent_unreachable:
      {503, "Biot not running", "This Biot is not running right now. Ask its owner to start it.",
       "Open Biot"},
    # The application answered badly or not at all. It is not the node and not the agent, so no
    # page that blames the Biot being stopped belongs here.
    invalid_response:
      {502, "No valid response",
       "The application did not return a valid response. Check what the application logged.",
       "Open Biot"},
    port_not_listening:
      {502, "Nothing to show",
       "The application is not listening on this port. Start the application, then try again.",
       "Open Biot"},
    too_large:
      {413, "Request too large",
       "This request is larger than this Biot accepts. Send a smaller request.", nil},
    too_many_streams: {503, "Try again", "This Biot is busy. Try again in a moment.", nil},
    timeout: {503, "Try again", "This Biot did not answer in time. Try again in a moment.", nil}
  }

  malformed_pages =
    for {reason, {status, title, message, link}} <- @pages,
        not (is_integer(status) and status in 400..599) or title == "" or message == "" or
          link == "" do
      reason
    end

  if malformed_pages != [] do
    raise "BiotWeb.Preview.Failure has malformed pages: #{inspect(malformed_pages)}"
  end

  @typedoc "One reason the preview proxy renders a failure page for."
  @type reason :: atom()

  @doc "Every reason this module renders, so a caller can check it covers them all."
  @spec reasons() :: [reason()]
  def reasons, do: @pages |> Map.keys() |> Enum.sort()

  @spec response(reason(), String.t()) :: {pos_integer(), String.t()}
  def response(reason, control_url) do
    {status, title, message, link} = Map.fetch!(@pages, reason)

    {status, page(title, message, link && {link, control_url})}
  end

  defp page(title, message, link) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="theme-color" content="#eef5f0" media="(prefers-color-scheme: light)" />
        <meta name="theme-color" content="#082a2f" media="(prefers-color-scheme: dark)" />
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
          h1 { font-size: 1.25rem; margin: 0 0 0.75rem; text-wrap: balance; }
          p { margin: 0 0 1rem; line-height: 1.5; }
          a { color: inherit; text-underline-offset: 0.2em; }
          a:hover { text-decoration-thickness: 0.15em; }
          a:focus-visible { outline: 2px solid currentColor; outline-offset: 0.2em; }
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

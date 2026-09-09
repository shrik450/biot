defmodule BiotWeb.Layouts do
  use BiotWeb, :html

  embed_templates "layouts/*"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main>
      {render_slot(@inner_block)}
    </main>
    """
  end
end

defmodule Mojentic.LLM.Gateways.OpenAIMessagesAdapterTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Gateways.OpenAIMessagesAdapter

  alias Mojentic.LLM.Message

  doctest OpenAIMessagesAdapter

  test "preserves remote image URLs and data URIs with original casing" do
    references = [
      "https://example.com/Photo.PNG?token=ABC",
      "http://example.com/photo.jpg",
      "HTTPS://example.com/Photo.PNG",
      "HtTp://example.com/Photo.JPG",
      "data:image/png;base64,AQID",
      "DaTa:image/png;base64,AQID"
    ]

    message = Message.user("Describe these") |> Message.with_images(references)
    [adapted] = OpenAIMessagesAdapter.adapt_messages([message])

    assert adapted.content ==
             [%{type: "text", text: "Describe these"}] ++
               Enum.map(references, &%{type: "image_url", image_url: %{url: &1}})
  end

  @tag :tmp_dir
  test "encodes local image files in order", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "image.PNG")
    File.write!(path, <<1, 2, 3>>)
    message = Message.user("") |> Message.with_images([path])

    assert OpenAIMessagesAdapter.adapt_messages([message]) == [
             %{
               role: "user",
               content: [%{type: "image_url", image_url: %{url: "data:image/png;base64,AQID"}}]
             }
           ]
  end
end

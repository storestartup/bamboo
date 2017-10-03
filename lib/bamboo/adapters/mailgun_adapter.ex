defmodule Bamboo.MailgunAdapter do
  @moduledoc """
  Sends email using Mailgun's API.

  Use this adapter to send emails through Mailgun's API. Requires that an API
  key and a domain are set in the config.

  ## Example config

      # In config/config.exs, or config.prod.exs, etc.
      config :my_app, MyApp.Mailer,
        adapter: Bamboo.MailgunAdapter,
        api_key: "my_api_key",
        domain: "your.domain"

      # Define a Mailer. Maybe in lib/my_app/mailer.ex
      defmodule MyApp.Mailer do
        use Bamboo.Mailer, otp_app: :my_app
      end
  """

  @service_name "Mailgun"
  @base_uri "https://api.mailgun.net/v3/"
  @behaviour Bamboo.Adapter

  alias Bamboo.{Email, Attachment}
  import Bamboo.ApiError

  def supports_attachments?, do: true

  def deliver(email, config) do
    body = to_mailgun_body(email)

    case :hackney.post(full_uri(config), headers(email, config), body, [:with_body]) do
      {:ok, status, headers, response} when status > 299 ->
        raise_api_error(@service_name, response, body)
      {:ok, status, headers, response} ->
        %{status_code: status, headers: headers, body: response}
      {:error, reason} ->
        raise_api_error(inspect(reason))
    end
  end

  @doc false
  def handle_config(config) do
    for setting <- [:api_key, :domain] do
      if config[setting] in [nil, ""] do
        raise_missing_setting_error(config, setting)
      end
    end
    config
  end

  defp raise_missing_setting_error(config, setting) do
    raise ArgumentError, """
    There was no #{setting} set for the Mailgun adapter.

    * Here are the config options that were passed in:

    #{inspect config}
    """
  end

  defp headers(email, config) do
    [
      {"Content-Type", content_type(email)},
      {"Authorization", "Basic #{auth_token(config)}"},
    ]
  end

  def content_type(%{attachments: []}), do: "application/x-www-form-urlencoded"
  def content_type(%{}), do: "multipart/form-data"

  defp auth_token(config) do
    Base.encode64("api:" <> config.api_key)
  end

  def to_mailgun_body(%Email{} = email) do
    %{}
    |> put_from(email)
    |> put_to(email)
    |> put_cc(email)
    |> put_bcc(email)
    |> put_reply_to(email)
    |> put_subject(email)
    |> put_html(email)
    |> put_text(email)
    |> put_headers(email)
    |> put_attachments(email)
    |> put_mailgun_vars(email)
    |> encode_body()
  end

  def put_from(body, %{from: from}), do: Map.put(body, :from, prepare_recipients(from))

  def put_to(body, %{to: to}), do: Map.put(body, :to, prepare_recipients(to))

  def put_cc(body, %{cc: []}), do: body
  def put_cc(body, %{cc: cc}), do: Map.put(body, :cc, prepare_recipients(cc))

  def put_bcc(body, %{bcc: []}), do: body
  def put_bcc(body, %{bcc: bcc}), do: Map.put(body, :bcc, prepare_recipients(bcc))

  defp put_reply_to(body, %Email{headers: %{"reply-to" => nil}}), do: body
  defp put_reply_to(body, %Email{headers: %{"reply-to" => address}}), do: Map.put(body, "h:Reply-To", address)
  defp put_reply_to(body, %Email{headers: _headers}), do: body

  defp put_subject(body, %{subject: subject}), do: Map.put(body, :subject, subject)

  defp put_text(body, %{text_body: nil}), do: body
  defp put_text(body, %{text_body: text_body}), do: Map.put(body, :text, text_body)

  defp put_html(body, %{html_body: nil}), do: body
  defp put_html(body, %{html_body: html_body}), do: Map.put(body, :html, html_body)

  defp put_headers(body, %Email{headers: headers}) do
    Enum.reduce(headers, body, fn({key, value}, acc) ->
      Map.put(acc, :"h:#{key}", value)
    end)
  end

  @mailgun_vars [:tag, :campaign, :testmode, :tracking, :"tracking-clicks", :"tracking-opens"]

  def put_mailgun_vars(body, %Email{private: private}) when is_map(private) do
    private
    |> Enum.filter(fn {k, _} -> Enum.member?(@mailgun_vars, k) end)
    |> Enum.reduce(body, fn({k, v}, acc) ->
      Map.put(acc, "o:#{k}", v)
    end)
  end
  def put_mailgun_vars(body, _), do: body

  defp put_attachments(body, %{attachments: []}), do: body
  defp put_attachments(body, %{attachments: attachments}) do
    attachment_data = attachments
    |> Enum.reverse()
    |> Enum.map(&prepare_file/1)
    Map.put(body, :attachments, attachment_data)
  end

  defp prepare_file(attach) do
    {"attachment", attach.data,
      {"form-data", [{~s/"name"/, ~s/"attachment"/},
        {~s/"filename"/, ~s/"#{attach.filename}"/}]},
      []}
  end

  def encode_body(%{attachments: attachments} = params) do
    {:multipart,
      params
      |> Map.drop([:attachments])
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Kernel.++(attachments)
    }
  end
  def encode_body(no_attachments), do: Plug.Conn.Query.encode(no_attachments)

  defp full_uri(config) do
    Application.get_env(:bamboo, :mailgun_base_uri, @base_uri)
    <> config.domain <> "/messages"
  end

  defp prepare_recipients(recipients) when is_list(recipients) do
    recipients
    |> Enum.map(&prepare_recipient/1)
    |> Enum.join(",")
  end
  defp prepare_recipients(r), do: prepare_recipient(r)

  defp prepare_recipient({nil, address}), do: address
  defp prepare_recipient({"", address}), do: address
  defp prepare_recipient({name, address}), do: "#{name} <#{address}>"
  defp prepare_recipient(r), do: r
end
